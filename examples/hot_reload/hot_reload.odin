#+build windows
package hot_reload

// Live++-style in-process hot reload for Odin (Windows / x64).
//
// On reload we recompile the whole program to a single COFF object
//
//     odin build <this-package> -build-mode:obj -use-single-module -out:hot.obj
//
// then load that object directly into the running process (no DLL), relocate it,
// and overwrite the prologue of each running `@(hot_reload)` procedure with a
// jump to the fresh code. Existing direct calls reach the new code; the process
// never restarts and its state is untouched.
//
// Relocations against *external* symbols (other procedures, runtime helpers, and
// globals) are resolved against the addresses in the already-running process via
// `runtime.hot_reload_symbol_table` — a {name, address, is_hot} table the compiler
// bakes into the exe when built with `-hot-reload`. Because a relocation to a
// global resolves to the exe's copy of that global, state on globals is preserved
// too. Object-local data (string/float constants) is taken from the loaded object.
//
// Build the exe with `-hot-reload` so the symbol table exists; otherwise only
// fully self-contained hot procedures (no external references) can be reloaded.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import win "core:sys/windows"

Hot_Func :: struct {
	name:     string,
	original: rawptr, // address of the currently-running procedure in this .exe
}

// --- COFF on-disk structures (x64) -----------------------------------------

Coff_File_Header :: struct #packed {
	machine:                 u16le,
	number_of_sections:      u16le,
	time_date_stamp:         u32le,
	pointer_to_symbol_table: u32le,
	number_of_symbols:       u32le,
	size_of_optional_header: u16le,
	characteristics:         u16le,
}

Coff_Section_Header :: struct #packed {
	name:                    [8]u8,
	virtual_size:            u32le,
	virtual_address:         u32le,
	size_of_raw_data:        u32le,
	pointer_to_raw_data:     u32le,
	pointer_to_relocations:  u32le,
	pointer_to_line_numbers: u32le,
	number_of_relocations:   u16le,
	number_of_line_numbers:  u16le,
	characteristics:         u32le,
}

Coff_Symbol :: struct #packed {
	name:                  [8]u8,
	value:                 u32le,
	section_number:        i16le,
	type:                  u16le,
	storage_class:         u8,
	number_of_aux_symbols: u8,
}

Coff_Reloc :: struct #packed {
	virtual_address:    u32le,
	symbol_table_index: u32le,
	type:               u16le,
}

IMAGE_FILE_MACHINE_AMD64 :: 0x8664

// x64 relocation kinds we handle.
IMAGE_REL_AMD64_ADDR64 :: 0x01
IMAGE_REL_AMD64_REL32  :: 0x04 // ..= 0x09 for REL32_1 .. REL32_5

COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

Running_Sym :: struct {
	address: rawptr,
	is_hot:  bool,
}

// Load `obj_path`, relocate it against this running process, and replace each
// procedure in `funcs` with its fresh implementation. Returns true if every
// requested function was patched.
load_and_patch :: proc(obj_path: string, funcs: []Hot_Func) -> bool {
	data, err := os.read_entire_file(obj_path, context.allocator)
	if err != nil {
		fmt.eprintln("[hot] could not read object:", obj_path, err)
		return false
	}
	defer delete(data)

	if len(data) < FILE_HDR_SIZE {
		fmt.eprintln("[hot] object too small")
		return false
	}
	hdr := (^Coff_File_Header)(raw_data(data))
	if int(hdr.machine) != IMAGE_FILE_MACHINE_AMD64 {
		fmt.eprintfln("[hot] unexpected machine 0x%x (need AMD64)", int(hdr.machine))
		return false
	}

	n_sections := int(hdr.number_of_sections)
	sec_off := FILE_HDR_SIZE + int(hdr.size_of_optional_header)
	sym_off := int(hdr.pointer_to_symbol_table)
	n_syms := int(hdr.number_of_symbols)
	strtab_off := sym_off + n_syms*COFF_SYMBOL_SIZE

	// Name -> address of every procedure and global in the running process.
	running := make(map[string]Running_Sym, context.temp_allocator)
	for s in runtime.hot_reload_symbol_table {
		running[s.name] = Running_Sym{s.address, s.is_hot}
	}
	if len(runtime.hot_reload_symbol_table) == 0 {
		fmt.eprintln("[hot] note: empty symbol table (build the exe with -hot-reload); only self-contained procedures will reload")
	}

	section_header :: proc(data: []byte, sec_off, i: int) -> ^Coff_Section_Header {
		return (^Coff_Section_Header)(raw_data(data[sec_off + i*SECTION_HDR_SIZE:]))
	}

	// 1) Lay every section out inside ONE contiguous block, then map that block
	//    within +/-2GB of the exe. This is essential: RIP-relative (REL32)
	//    references from the loaded code to the exe's procedures and globals must
	//    fit in a signed 32-bit displacement, and inter-section REL32 references
	//    must reach across the block too. A far-away VirtualAlloc would overflow.
	PAGE :: 0x1000
	section_bases := make([]rawptr, n_sections + 1, context.temp_allocator)
	offsets := make([]int, n_sections + 1, context.temp_allocator)
	total := 0
	for i in 0 ..< n_sections {
		sh := section_header(data, sec_off, i)
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		if size == 0 {
			offsets[i + 1] = -1
			continue
		}
		total = ((total + PAGE - 1) / PAGE) * PAGE
		offsets[i + 1] = total
		total += size
	}
	total = ((total + PAGE - 1) / PAGE) * PAGE

	block := alloc_near_exe(total)
	if block == nil {
		fmt.eprintln("[hot] could not reserve memory within 2GB of the exe")
		return false
	}
	text_base: rawptr
	text_size: int
	for i in 0 ..< n_sections {
		if offsets[i + 1] < 0 {
			continue
		}
		sh := section_header(data, sec_off, i)
		base := rawptr(uintptr(block) + uintptr(offsets[i + 1]))
		section_bases[i + 1] = base
		if int(sh.size_of_raw_data) > 0 && int(sh.pointer_to_raw_data) != 0 {
			intrinsics.mem_copy(base, raw_data(data[int(sh.pointer_to_raw_data):]), int(sh.size_of_raw_data))
		}
		if section_name(sh) == ".text" {
			text_base = base
			text_size = int(sh.size_of_raw_data)
		}
	}

	// 2) Resolve every symbol slot to a runtime address.
	//    - defined & in the running exe & not hot -> the exe's address (reuse / preserve globals)
	//    - defined & hot                          -> the object's fresh copy (new code)
	//    - defined & object-local                 -> the object's loaded copy (constants, labels)
	//    - undefined external                     -> the exe's address, else unresolved
	resolved := make([]rawptr, n_syms, context.temp_allocator)
	{
		i := 0
		for i < n_syms {
			sym := coff_symbol(data, sym_off, i)
			name := symbol_name(sym, data, strtab_off)
			sn := int(sym.section_number)
			if sn > 0 && section_bases[sn] != nil {
				obj_addr := rawptr(uintptr(section_bases[sn]) + uintptr(sym.value))
				if rs, ok := running[name]; ok {
					resolved[i] = rs.is_hot ? obj_addr : rs.address
				} else {
					resolved[i] = obj_addr
				}
			} else if sn == 0 {
				if rs, ok := running[name]; ok {
					resolved[i] = rs.address
				}
			}
			i += 1 + int(sym.number_of_aux_symbols)
		}
	}

	// 3) Apply relocations for every section.
	unresolved, unsupported := 0, 0
	for i in 0 ..< n_sections {
		sh := section_header(data, sec_off, i)
		base := section_bases[i + 1]
		if base == nil {
			continue
		}
		nreloc := int(sh.number_of_relocations)
		roff := int(sh.pointer_to_relocations)
		for r in 0 ..< nreloc {
			rel := (^Coff_Reloc)(raw_data(data[roff + r*RELOC_SIZE:]))
			target := resolved[int(rel.symbol_table_index)]
			if target == nil {
				unresolved += 1
				continue
			}
			site := uintptr(base) + uintptr(rel.virtual_address)
			switch int(rel.type) {
			case IMAGE_REL_AMD64_ADDR64:
				(^u64)(site)^ = (^u64)(site)^ + u64(uintptr(target))
			case IMAGE_REL_AMD64_REL32 ..= IMAGE_REL_AMD64_REL32 + 5:
				extra := i64(int(rel.type) - IMAGE_REL_AMD64_REL32) // REL32_1..5 bias
				addend := i64((^i32)(site)^)
				next := i64(site) + 4 + extra
				(^i32)(site)^ = i32(i64(uintptr(target)) + addend - next)
			case:
				unsupported += 1
			}
		}
	}

	// Freshly written executable code — make the instruction cache coherent.
	if text_base != nil {
		win.FlushInstructionCache(win.GetCurrentProcess(), text_base, win.SIZE_T(text_size))
	}
	if unresolved > 0 || unsupported > 0 {
		fmt.eprintfln("[hot] note: %d unresolved and %d unsupported relocations (fine if only in code you don't call)", unresolved, unsupported)
	}

	// 4) Patch each requested procedure's running prologue to jump to its fresh code.
	patched := 0
	for f in funcs {
		new_addr, found := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, f.name)
		if !found {
			fmt.eprintfln("[hot] symbol not found in object: %s", f.name)
			continue
		}
		if patch_jump(f.original, new_addr) {
			fmt.printfln("[hot] patched %s: %p -> %p", f.name, f.original, new_addr)
			patched += 1
		}
	}
	return patched == len(funcs)
}

// Find a defined function symbol by name and return its runtime address in the
// freshly mapped code.
find_symbol_address :: proc(data: []byte, sym_off, n_syms, strtab_off: int, section_bases: []rawptr, name: string) -> (addr: rawptr, ok: bool) {
	i := 0
	for i < n_syms {
		sym := coff_symbol(data, sym_off, i)
		sn := int(sym.section_number)
		if sn > 0 && section_bases[sn] != nil && symbol_name(sym, data, strtab_off) == name {
			return rawptr(uintptr(section_bases[sn]) + uintptr(sym.value)), true
		}
		i += 1 + int(sym.number_of_aux_symbols)
	}
	return nil, false
}

// Overwrite the first 14 bytes of `original` with:  FF 25 00 00 00 00  <qword target>
// (a RIP-relative absolute indirect jump whose 64-bit target follows inline).
// Safe because Odin/LLVM aligns every procedure to a 16-byte boundary.
patch_jump :: proc(original: rawptr, target: rawptr) -> bool {
	PATCH_LEN :: 14
	old_protect: win.DWORD
	if !win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), win.PAGE_EXECUTE_READWRITE, &old_protect) {
		fmt.eprintln("[hot] VirtualProtect failed")
		return false
	}
	b := ([^]u8)(original)
	b[0] = 0xFF
	b[1] = 0x25
	b[2] = 0x00; b[3] = 0x00; b[4] = 0x00; b[5] = 0x00
	(^u64)(&b[6])^ = u64(uintptr(target))

	restored: win.DWORD
	win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), old_protect, &restored)
	win.FlushInstructionCache(win.GetCurrentProcess(), original, win.SIZE_T(PATCH_LEN))
	return true
}

// --- helpers ----------------------------------------------------------------

// Reserve `size` bytes within +/-2GB of the exe's image base, so RIP-relative
// references from the loaded code to the exe resolve within a 32-bit range.
alloc_near_exe :: proc(size: int) -> rawptr {
	base := uintptr(win.GetModuleHandleW(nil))
	sz := win.SIZE_T(size)
	step :: uintptr(0x0010_0000) // 1 MiB (a multiple of the 64 KiB allocation granularity)
	limit :: uintptr(0x6000_0000) // stay well inside 2 GiB
	for off := step; off <= limit; off += step {
		if base > off {
			if m := win.VirtualAlloc(rawptr(base - off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
				return m
			}
		}
		if m := win.VirtualAlloc(rawptr(base + off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
			return m
		}
	}
	return nil
}

coff_symbol :: proc(data: []byte, sym_off, i: int) -> ^Coff_Symbol {
	return (^Coff_Symbol)(raw_data(data[sym_off + i*COFF_SYMBOL_SIZE:]))
}

section_name :: proc(sh: ^Coff_Section_Header) -> string {
	n := 0
	for n < 8 && sh.name[n] != 0 {
		n += 1
	}
	return string(sh.name[:n])
}

symbol_name :: proc(sym: ^Coff_Symbol, data: []byte, strtab_off: int) -> string {
	// If the first 4 bytes are zero, the name is an offset into the string table.
	if sym.name[0] == 0 && sym.name[1] == 0 && sym.name[2] == 0 && sym.name[3] == 0 {
		off := int((^u32le)(&sym.name[4])^)
		p := strtab_off + off
		n := 0
		for p + n < len(data) && data[p + n] != 0 {
			n += 1
		}
		return string(data[p : p + n])
	}
	n := 0
	for n < 8 && sym.name[n] != 0 {
		n += 1
	}
	return string(sym.name[:n])
}
