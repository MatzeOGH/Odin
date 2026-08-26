#+build windows
package hot_reload

// Live++-style in-process hot reload for Odin (Windows / x64).
//
// Recompile the whole program to a single COFF object:
//
//     odin build <pkg> -build-mode:obj -use-single-module -hot-reload -hot-reload-manifest:<path> -out:hot.obj
//
// then call `apply("hot.obj")` from the running process. The object is loaded
// directly into the process (no DLL), relocated, and the prologue of each running
// `@(hot_reload)` procedure is overwritten with a jump to the fresh code. Existing
// direct calls reach the new code; the process never restarts and its state is
// untouched.
//
// Relocations against *external* symbols (other procedures, runtime helpers, and
// globals) are resolved against the addresses in the already-running process via
// `runtime.hot_reload_symbol_table` — the table the compiler bakes into the exe
// when built with `-hot-reload`. A relocation to an existing global resolves to
// the exe's copy, so global state is preserved.
//
// New symbols across a reload:
//   - New *procedures* called from hot code link automatically (their code lives
//     in the loaded object; callers reach them via relocations).
//   - New *globals* are placed by the compiler into a reserved arena
//     (`__odin_hot_reload_global_arena`) that lives in the exe, so references
//     resolve to stable in-image storage and their state persists across every
//     subsequent reload. New globals are zero-initialized.
//
// Build the exe with `-hot-reload` (and the same `-hot-reload-manifest`) so the
// table and arena exist; otherwise only fully self-contained hot procedures can
// be reloaded.
//
// The object's `.pdata`/`.xdata` unwind info is registered with `RtlAddFunctionTable`
// (with the loaded block as the image base), so Windows x64 stack walking works through
// hot code: `panic`/`assert` backtraces, the runtime's hardware-fault handler, and a
// debugger's call stack all unwind correctly across hot frames. This is about stack
// *unwinding* (Odin has no exceptions); it does not make hot code source-debuggable.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
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
IMAGE_REL_AMD64_ADDR64   :: 0x01
IMAGE_REL_AMD64_ADDR32NB :: 0x03 // 32-bit image-base-relative RVA (.pdata/.xdata unwind)
IMAGE_REL_AMD64_REL32    :: 0x04 // ..= 0x09 for REL32_1 .. REL32_5
IMAGE_REL_AMD64_SECREL :: 0x0B // 32-bit offset of a symbol from the start of its section (TLS access)

COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

Running_Sym :: struct {
	address: rawptr,
	is_hot:  bool,
}

// One entry of the compiler-emitted `__odin_hot_reload_new_global_inits` table: a
// new global's compile-time constant initializer. The loader copies `size` bytes
// from `blob` into the exe arena at `arena_offset`, once, gated by the arena byte
// at `flag_offset`. Layout must match the C++ emitter in src/llvm_backend.cpp.
New_Global_Init :: struct {
	arena_offset: i64,
	flag_offset:  i64,
	size:         i64,
	blob:         rawptr,
}

// Reload `obj_path` into this running process, patching every `@(hot_reload)`
// procedure to its fresh implementation. The set of procedures to patch is
// discovered from `runtime.hot_reload_symbol_table`, so the caller does not have
// to list them. Returns true if every hot procedure was patched.
apply :: proc(obj_path: string) -> bool {
	funcs := make([dynamic]Hot_Func, context.temp_allocator)
	for s in runtime.hot_reload_symbol_table {
		if s.is_hot {
			append(&funcs, Hot_Func{s.name, s.address})
		}
	}
	if len(funcs) == 0 {
		fmt.eprintln("[hot] no @(hot_reload) procedures found (build the exe with -hot-reload)")
		return false
	}
	return load_and_patch(obj_path, funcs[:])
}

// Load `obj_path`, relocate it against this running process, and replace each
// procedure in `funcs` with its fresh implementation. Returns true if every
// requested function was patched. Prefer `apply` unless you need to control the
// exact set of procedures.
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

	// Name -> address of every procedure and global in the running process, plus
	// name -> exe TLS-block offset for every thread-local (its `address` is an
	// accessor proc returning `&var`, so offset = &var - the exe's TLS block base).
	running := make(map[string]Running_Sym, context.temp_allocator)
	tls_off := make(map[string]uintptr, context.temp_allocator)
	tls_base := hr_tls_block_base()
	for s in runtime.hot_reload_symbol_table {
		if s.kind == .TLS {
			if tls_base != 0 && s.address != nil {
				addr := (transmute(proc "c" () -> rawptr) s.address)()
				tls_off[s.name] = uintptr(addr) - tls_base
			}
			continue
		}
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
	//    - defined & object-local                 -> the object's loaded copy (new procs, constants, labels)
	//    - undefined external                     -> the exe's address, else unresolved
	//
	// New globals reach here as an undefined external reference to
	// `__odin_hot_reload_global_arena` (resolved to the exe's arena) plus a
	// per-site byte offset baked into the relocation addend — so they land in
	// stable in-image storage. New procedures are object-local and resolve to
	// their fresh copy, callable from patched and other new code.
	// Near-block scratch for trampolines (far REL32 targets) and import cells
	// (`__imp_X` slots). Allocated near the loaded block so a REL32 can reach them.
	near_arena := Near_Arena{
		near   = uintptr(block),
		tramps = make(map[uintptr]rawptr, context.temp_allocator),
		cells  = make(map[uintptr]rawptr, context.temp_allocator),
	}

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
				// Undefined external: an Odin symbol (running table), a C-runtime
				// helper / _tls_index / Windows-API export, or an `__imp_` cell.
				resolved[i] = hr_resolve(name, running, &near_arena)
			}
			i += 1 + int(sym.number_of_aux_symbols)
		}
	}

	// 3) Apply relocations for every section.
	unresolved, unsupported := 0, 0
	unresolved_text := 0 // unresolved relocations that land in executable code -> fatal
	for i in 0 ..< n_sections {
		sh := section_header(data, sec_off, i)
		base := section_bases[i + 1]
		if base == nil {
			continue
		}
		is_text := section_name(sh) == ".text"
		nreloc := int(sh.number_of_relocations)
		roff := int(sh.pointer_to_relocations)
		for r in 0 ..< nreloc {
			rel := (^Coff_Reloc)(raw_data(data[roff + r*RELOC_SIZE:]))

			// Thread-local access: rewrite the per-variable SECREL offset to the
			// variable's offset in the EXE's TLS block (the object's own .tls$
			// layout differs), so hot code reads the running threads' real slots.
			if int(rel.type) == IMAGE_REL_AMD64_SECREL {
				site := uintptr(base) + uintptr(rel.virtual_address)
				usym := coff_symbol(data, sym_off, int(rel.symbol_table_index))
				sname := symbol_name(usym, data, strtab_off)
				if off, ok := tls_off[sname]; ok {
					// Absolute 32-bit section offset + any per-site addend already
					// present (e.g. an array-element index within the variable).
					(^u32)(site)^ = u32(off) + (^u32)(site)^
				} else {
					unresolved += 1
					if is_text {
						unresolved_text += 1
						fmt.eprintfln("[hot] thread-local not present in exe (a new thread-local cannot be added across a reload): %s", sname)
					}
				}
				continue
			}

			target := resolved[int(rel.symbol_table_index)]
			if target == nil {
				unresolved += 1
				if is_text {
					unresolved_text += 1
					usym := coff_symbol(data, sym_off, int(rel.symbol_table_index))
					uname := symbol_name(usym, data, strtab_off)
					fmt.eprintfln("[hot] unresolved symbol in executable code: %s", uname)
					fmt.eprintfln("[hot]   (if this is a foreign-library function: its code is not present in the running image. Reference it once in the base build, or link the archive whole, e.g. /WHOLEARCHIVE. Adding a library not linked into the base build is not supported. A base build without -debug also has no PDB to resolve non-exported symbols.)")
				}
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
				disp := i64(uintptr(target)) + addend - next
				if disp < -0x8000_0000 || disp > 0x7FFF_FFFF {
					// Target (e.g. a CRT/DLL export) is out of REL32 range: route the
					// reference through a near trampoline that jumps the full 64 bits.
					final := u64(i64(uintptr(target)) + addend)
					if th := hr_trampoline_for(&near_arena, uintptr(final)); th != nil {
						disp = i64(uintptr(th)) - next
					} else if is_text {
						unresolved_text += 1
						fmt.eprintln("[hot] could not allocate trampoline for out-of-range target")
					}
				}
				(^i32)(site)^ = i32(disp)
			case IMAGE_REL_AMD64_ADDR32NB:
				// 32-bit image-relative RVA (fills .pdata RUNTIME_FUNCTION fields and
				// .xdata handler/chain pointers). The whole object lives in `block`,
				// which we pass to RtlAddFunctionTable as the image base, so the RVA is
				// `target - block` plus any inline addend (e.g. an .pdata EndAddress that
				// points at func+size). Assumes the target is in-block (always true for
				// unwind data); an external target would wrap to a bogus RVA.
				addend := i64((^i32)(site)^)
				rva := i64(uintptr(target)) - i64(uintptr(block)) + addend
				(^u32)(site)^ = u32(rva)
			case:
				unsupported += 1
			}
		}
	}

	// Freshly written executable code — make the instruction cache coherent.
	if text_base != nil {
		win.FlushInstructionCache(win.GetCurrentProcess(), text_base, win.SIZE_T(text_size))
	}

	// 3.1) Register the object's .pdata so the OS unwinder can find unwind info for RIPs
	//      in the hot code. Odin has no language exceptions, but Windows x64 stack walking
	//      is table-driven (no frame-pointer chain), so these tables are what a `panic`/
	//      `assert` backtrace, the runtime's hardware-fault handler (a segfault/div0 in a
	//      hot proc raises SEH even without `try`), and a debugger's call-stack window all
	//      rely on. Without this, a walk that crosses a hot frame finds no RUNTIME_FUNCTION,
	//      treats it as a leaf, recovers the wrong return address, and corrupts. Normal
	//      call/return is unaffected. The .pdata RVAs were fixed up above (ADDR32NB)
	//      relative to `block`, so `block` is the image base. NOTE: this only fixes
	//      UNWINDING; it does not make hot code source-debuggable (no PDB/module is
	//      registered for the mapped block, so no source-line breakpoints in hot code).
	for i in 0 ..< n_sections {
		sh := section_header(data, sec_off, i)
		if section_name(sh) != ".pdata" {
			continue
		}
		pbase := section_bases[i + 1]
		if pbase == nil {
			continue
		}
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		count := u32(size / size_of(win.RUNTIME_FUNCTION))
		if count > 0 {
			if !win.RtlAddFunctionTable(win.PRUNTIME_FUNCTION(pbase), win.DWORD(count), win.DWORD64(uintptr(block))) {
				fmt.eprintln("[hot] RtlAddFunctionTable failed; stack traces through hot code may be wrong")
			}
		}
	}
	if unresolved > 0 || unsupported > 0 {
		fmt.eprintfln("[hot] note: %d unresolved and %d unsupported relocations (fine if only in code you don't call)", unresolved, unsupported)
	}
	// An unresolved relocation inside executable code is a landmine: calling it jumps
	// to a bogus address and crashes. Fail loudly instead of patching in broken code.
	if unresolved_text > 0 {
		fmt.eprintfln("[hot] aborting reload: %d unresolved relocation(s) in executable code (see names above)", unresolved_text)
		return false
	}

	// 3.5) Apply once-only constant initializers for brand-new globals. Each entry
	//      copies its constant blob into the exe's arena at `arena_offset` iff the
	//      `flag` byte is still 0, then sets the flag — so re-applying an object (or
	//      any later reload) never clobbers state the running program accumulated.
	//      (Relocations were applied above, so `blob` pointers are already correct.)
	if tbl_addr, ok := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, "__odin_hot_reload_new_global_inits"); ok {
		if arena, arena_ok := running["__odin_hot_reload_global_arena"]; arena_ok {
			count := (^i64)(tbl_addr)^
			entries := ([^]New_Global_Init)(rawptr(uintptr(tbl_addr) + 8))
			for k in 0 ..< int(count) {
				e := entries[k]
				flag := (^u8)(uintptr(arena.address) + uintptr(e.flag_offset))
				if flag^ == 0 {
					dst := rawptr(uintptr(arena.address) + uintptr(e.arena_offset))
					intrinsics.mem_copy(dst, e.blob, int(e.size))
					flag^ = 1
				}
			}
		}
	}

	// 4) Patch each requested procedure's running entry to jump to its fresh code.
	//    Resolve every fresh address first, then patch the whole batch with all other
	//    threads suspended and only once no thread is parked in a region we overwrite —
	//    so a concurrent thread never executes a half-written instruction.
	Target :: struct {
		name:            string,
		original, fresh: rawptr,
	}
	targets := make([dynamic]Target, context.temp_allocator)
	for f in funcs {
		fresh, found := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, f.name)
		if !found {
			fmt.eprintfln("[hot] symbol not found in object: %s", f.name)
			continue
		}
		append(&targets, Target{f.name, f.original, fresh})
	}
	if len(targets) == 0 {
		return false
	}

	// Guard PATCH_LEN bytes at each entry: the atomic path only touches 2, but the
	// fallback overwrite touches PATCH_LEN, so the larger region keeps either safe.
	regions := make([]Patch_Region, len(targets), context.temp_allocator)
	for t, i in targets {
		regions[i] = Patch_Region{uintptr(t.original), uintptr(t.original) + PATCH_LEN}
	}

	// Suspend the world; if a thread is parked in a prologue we must overwrite, let it
	// run and retry rather than corrupt it.
	MAX_ATTEMPTS :: 100
	handles: [dynamic]win.HANDLE
	for attempt := 0; ; attempt += 1 {
		handles = hr_suspend_others()
		if !hr_ip_conflicts(handles, regions) {
			break
		}
		hr_resume(handles)
		if attempt + 1 >= MAX_ATTEMPTS {
			fmt.eprintfln("[hot] aborting reload: a thread stayed inside a procedure prologue for %d attempts", MAX_ATTEMPTS)
			return false
		}
		win.Sleep(1)
	}

	patched := 0
	for t in targets {
		ok, atomic := patch_jump(t.original, t.fresh)
		if ok {
			fmt.printfln("[hot] patched %s: %p -> %p (%s)", t.name, t.original, t.fresh, atomic ? "atomic" : "overwrite")
			patched += 1
		}
	}
	hr_resume(handles)
	return patched == len(targets)
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

PATCH_LEN :: 14 // bytes of a `FF 25` RIP-relative absolute indirect jump
PAD_LEN   :: 16 // pre-function pad reserved by `/FUNCTIONPADMIN:16` (see -hot-reload linker flags)

HR_DEBUG_PAD :: #config(HR_DEBUG_PAD, false) // dump pad + entry bytes on each patch

// Write a RIP-relative absolute indirect jump at `dst`:
//   FF 25 00 00 00 00   <qword target>
// (disp32 = 0, so the 64-bit target sits inline right after the 6-byte opcode).
// `dst` must already be writable. Shared by the pad/prologue patchers and the
// far-call trampoline.
@(private)
hr_write_abs_jump :: proc(dst: [^]u8, target: rawptr) {
	dst[0] = 0xFF; dst[1] = 0x25
	dst[2] = 0x00; dst[3] = 0x00; dst[4] = 0x00; dst[5] = 0x00
	(^u64)(&dst[6])^ = u64(uintptr(target))
}

// Redirect the running procedure at `original` to `target`. Prefers the atomic
// short-jump publish (Layer 2) and falls back to the 14-byte prologue overwrite.
// Must be called with all other threads suspended (see `hr_suspend_others`) so the
// pad write and any fallback overwrite cannot race a concurrently executing thread.
// Returns whether the patch succeeded and which path was taken.
patch_jump :: proc(original: rawptr, target: rawptr) -> (ok: bool, atomic: bool) {
	if hr_patch_atomic(original, target) {
		return true, true
	}
	return hr_patch_overwrite(original, target), false
}

// Atomic publish via the MSVC-style hotpatch prologue + `/FUNCTIONPADMIN` pad:
//   1. write the full 14-byte far jump into the 16-byte pad ahead of the function
//      (nobody executes the pad, so this write is invisible to running code);
//   2. flip the 2-byte hotpatch entry (`mov edi,edi` = 8B FF) to `EB EE`
//      (jmp -18, i.e. back to the pad) with ONE aligned 16-bit store.
// The entry is 16-byte aligned, so the 2-byte store is atomic and single-cacheline:
// every core observes either the old valid 2-byte instruction or the new valid short
// jump, never a torn mix. Returns false (so the caller falls back) if there is no
// usable pad — e.g. the exe was not built with the `-hot-reload` linker flags.
@(private)
hr_patch_atomic :: proc(original: rawptr, target: rawptr) -> bool {
	if uintptr(original) < PAD_LEN {
		return false
	}
	pad := rawptr(uintptr(original) - PAD_LEN)
	pb := ([^]u8)(pad)
	when HR_DEBUG_PAD {
		eb := ([^]u8)(original)
		fmt.eprintfln("[hot] pad@%p: % x | entry: %02x %02x", pad,
			pb[0:PAD_LEN], eb[0], eb[1])
	}
	// Usable iff the pad is still the compiler-emitted `patchable-function-prefix`
	// filler (0x90 NOP, or 0xCC if a linker also padded) or already holds our own jump
	// from a previous reload (FF 25 ...). Anything else means there is no pad here and
	// we must fall back to the prologue overwrite.
	usable := pb[0] == 0xFF && pb[1] == 0x25
	if !usable {
		usable = true
		for i in 0 ..< PATCH_LEN {
			if pb[i] != 0x90 && pb[i] != 0xCC {
				usable = false
				break
			}
		}
	}
	if !usable {
		return false
	}

	// Cover the pad through the 2-byte entry (they may straddle a page boundary).
	region_len := win.SIZE_T(PAD_LEN + 2)
	old: win.DWORD
	if !win.VirtualProtect(pad, region_len, win.PAGE_EXECUTE_READWRITE, &old) {
		return false
	}

	hr_write_abs_jump(pb, target)
	win.FlushInstructionCache(win.GetCurrentProcess(), pad, win.SIZE_T(PATCH_LEN))

	// EB EE == jmp rel8 -18: from the end of the 2-byte entry (original+2) back to
	// the pad (original-16). One atomic store; then flush the two entry bytes.
	intrinsics.atomic_store((^u16)(original), u16(0xEEEB))
	win.FlushInstructionCache(win.GetCurrentProcess(), original, 2)

	restored: win.DWORD
	win.VirtualProtect(pad, region_len, old, &restored)
	return true
}

// Fallback: overwrite the first 14 bytes of `original` with the far jump. Safe only
// because the caller has suspended every other thread (a concurrent thread could
// otherwise execute the half-written prologue). Relies on 16-byte proc alignment.
@(private)
hr_patch_overwrite :: proc(original: rawptr, target: rawptr) -> bool {
	old_protect: win.DWORD
	if !win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), win.PAGE_EXECUTE_READWRITE, &old_protect) {
		fmt.eprintln("[hot] VirtualProtect failed")
		return false
	}
	hr_write_abs_jump(([^]u8)(original), target)
	restored: win.DWORD
	win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), old_protect, &restored)
	win.FlushInstructionCache(win.GetCurrentProcess(), original, win.SIZE_T(PATCH_LEN))
	return true
}

// --- thread coordination (stop-the-world patching) --------------------------
//
// Overwriting a running procedure is only safe if no other thread is executing the
// bytes being changed. We suspend every other thread in the process, verify none is
// parked in a region we will overwrite, patch, then resume. The atomic publish above
// shrinks the unsafe region to the 2-byte entry, but the pad write and the 14-byte
// fallback still need the world stopped.

Patch_Region :: struct {
	lo, hi: uintptr,
}

// Suspend every thread in this process except the caller. Returns the OpenThread
// handles of the suspended threads; pass them to `hr_resume`.
@(private)
hr_suspend_others :: proc() -> [dynamic]win.HANDLE {
	handles := make([dynamic]win.HANDLE, context.temp_allocator)
	me_pid := win.GetCurrentProcessId()
	me_tid := win.GetCurrentThreadId()
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0)
	if snap == win.INVALID_HANDLE_VALUE {
		return handles
	}
	defer win.CloseHandle(snap)

	te: win.THREADENTRY32
	te.dwSize = size_of(win.THREADENTRY32)
	ok := win.Thread32First(snap, &te)
	for ok {
		if te.th32OwnerProcessID == me_pid && te.th32ThreadID != me_tid {
			h := win.OpenThread(
				win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_SET_CONTEXT,
				win.FALSE, te.th32ThreadID,
			)
			if h != nil {
				if win.SuspendThread(h) != ~win.DWORD(0) { // (DWORD)-1 on failure
					append(&handles, h)
				} else {
					win.CloseHandle(h)
				}
			}
		}
		te.dwSize = size_of(win.THREADENTRY32)
		ok = win.Thread32Next(snap, &te)
	}
	return handles
}

@(private)
hr_resume :: proc(handles: [dynamic]win.HANDLE) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
}

// True if any suspended thread's instruction pointer sits inside a region we are
// about to overwrite (so patching would corrupt the instruction it will execute).
@(private)
hr_ip_conflicts :: proc(handles: [dynamic]win.HANDLE, regions: []Patch_Region) -> bool {
	for h in handles {
		ctx: win.CONTEXT
		ctx.ContextFlags = win.CONTEXT_CONTROL
		if !win.GetThreadContext(h, &ctx) {
			continue // cannot read; best-effort
		}
		rip := uintptr(ctx.Rip)
		for reg in regions {
			if rip >= reg.lo && rip < reg.hi {
				return true
			}
		}
	}
	return false
}

// --- helpers ----------------------------------------------------------------

// Reserve `size` bytes within +/-2GB of the exe's image base, so RIP-relative
// references from the loaded code to the exe resolve within a 32-bit range.
alloc_near_exe :: proc(size: int) -> rawptr {
	return alloc_near(uintptr(win.GetModuleHandleW(nil)), size)
}

// Reserve `size` bytes within +/-2GB of `near`, so a RIP-relative (REL32)
// reference from code near `near` to this block fits in a signed 32-bit range.
alloc_near :: proc(near: uintptr, size: int) -> rawptr {
	sz := win.SIZE_T(size)
	step :: uintptr(0x0010_0000) // 1 MiB (a multiple of the 64 KiB allocation granularity)
	limit :: uintptr(0x6000_0000) // stay well inside 2 GiB
	for off := step; off <= limit; off += step {
		if near > off {
			if m := win.VirtualAlloc(rawptr(near - off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
				return m
			}
		}
		if m := win.VirtualAlloc(rawptr(near + off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
			return m
		}
	}
	return nil
}

// --- general external-symbol resolution -------------------------------------
//
// A reload object references symbols that are neither defined in the object nor
// present in `runtime.hot_reload_symbol_table` (Odin procs/globals): C runtime
// helpers the backend synthesises (`memcpy`/`memset`/`memmove`/`memcmp`), the TLS
// index `_tls_index`, and any Windows-API import. These must resolve to an address
// in the running process, or a call through them faults. We resolve them in two
// ways, by how they can be found at runtime:
//   - exported by a loaded module  -> GetProcAddress across the process's modules
//   - non-exported but in-image     -> referenced here by exact link name

// `_tls_index` is not exported, so it can only be reached by referencing the exe's
// own copy by link name. Its VALUE names the TLS slot the running threads set up;
// reloaded code must read THIS one or it lands in the wrong slot (garbage context).
foreign {
	@(link_name="_tls_index") _hr_tls_index: u32
}

// The exe's TLS block base for the current thread: TEB.ThreadLocalStoragePointer
// (gs:[0x58], an array of per-module TLS block bases) indexed by the exe's
// `_tls_index`. Reloaded code accesses a thread-local as `base + <exe SECREL
// offset>`; the loader computes each offset relative to THIS base (offsets are
// thread-independent, so computing on the loader thread is valid for all threads).
@(private)
hr_tls_block_base :: proc "contextless" () -> uintptr {
	read_teb_tls :: asm() -> (r: u64) { mov r, [%gs:0x58]; }
	teb_tls := uintptr(read_teb_tls())
	if teb_tls == 0 {
		return 0
	}
	arr := cast([^]uintptr)teb_tls
	return arr[_hr_tls_index]
}


// Resolve an undefined-external symbol referenced by the reload object to an address
// in the running process, or nil. Handles three forms:
//   - direct Odin symbol      -> the running symbol table (`running`)
//   - direct C/OS symbol       -> export lookup, then non-exported in-image set
//   - `__imp_X` (import cell)  -> a synthesised pointer cell holding the address of X
@(private)
hr_resolve :: proc(name: string, running: map[string]Running_Sym, na: ^Near_Arena) -> rawptr {
	if rs, ok := running[name]; ok {
		return rs.address
	}
	if p := hr_resolve_external(name); p != nil {
		return p
	}
	// `__imp_X` is an indirection slot the object reads to get X's address. There is
	// no such slot for an in-image/static symbol, so synthesise one near the block.
	IMP :: "__imp_"
	if strings.has_prefix(name, IMP) {
		real := name[len(IMP):]
		a: rawptr
		if rs, ok := running[real]; ok {
			a = rs.address
		} else {
			a = hr_resolve_external(real)
		}
		if a != nil {
			return hr_imp_cell(na, uintptr(a))
		}
	}
	return nil
}

// Resolve `name` to an address in the running process, or nil. First an export
// lookup (covers memcpy/memset/memmove/memcmp and every Windows-API/CRT export),
// then the small set of non-exported in-image symbols, then a PDB lookup (finds
// non-exported, in-image symbols such as statically-linked foreign-library
// functions the base build linked but this source had not referenced before).
@(private)
hr_resolve_external :: proc(name: string) -> rawptr {
	if p := hr_resolve_exported(name); p != nil {
		return p
	}
	switch name {
	case "_tls_index": return &_hr_tls_index
	}
	if p := hr_resolve_pdb(name); p != nil {
		return p
	}
	return nil
}

// GetProcAddress over the always-loaded modules that carry the C-runtime surface,
// plus the exe itself. ntdll exports memcpy/memset/memmove/memcmp, so it comes first.
@(private)
hr_resolve_exported :: proc(name: string) -> rawptr {
	cname, err := strings.clone_to_cstring(name, context.temp_allocator)
	if err != nil {
		return nil
	}
	if h := win.GetModuleHandleW(nil); h != nil { // the exe
		if p := win.GetProcAddress(h, cname); p != nil { return p }
	}
	mods := [?]win.wstring{ win.L("ntdll.dll"), win.L("ucrtbase.dll"), win.L("kernel32.dll") }
	for mn in mods {
		if h := win.GetModuleHandleW(mn); h != nil {
			if p := win.GetProcAddress(h, cname); p != nil { return p }
		}
	}
	return nil
}

// Whether DbgHelp has been initialized for this process. SymInitialize with
// fInvadeProcess loads symbols for every currently-loaded module, including the
// exe's PDB — kept warm across reloads (never SymCleanup'd).
@(private)
_hr_dbghelp_ready: bool

@(private)
hr_dbghelp_ensure :: proc() -> bool {
	if _hr_dbghelp_ready {
		return true
	}
	if !win.SymInitialize(win.GetCurrentProcess(), nil, true) {
		return false
	}
	win.SymSetOptions(win.SYMOPT_DEFERRED_LOADS)
	_hr_dbghelp_ready = true
	return true
}

// Resolve `name` via the running exe's PDB. This reaches non-exported, in-image
// symbols the export/table lookups miss — in particular a statically-linked
// foreign-library function (e.g. a `vendor:raylib` proc) whose object member the
// linker already pulled into the exe, but which this source had not referenced
// before the hot edit. Requires the exe to have been built with `-debug` (a PDB
// present next to it); returns nil otherwise. COFF symbol names are plain C names
// (no x64 mangling), which match the PDB's public symbol names.
@(private)
hr_resolve_pdb :: proc(name: string) -> rawptr {
	if !hr_dbghelp_ensure() {
		return nil
	}
	wname := win.utf8_to_wstring(name, context.temp_allocator)
	if wname == nil {
		return nil
	}
	data: [size_of(win.SYMBOL_INFOW) + size_of([256]win.WCHAR)]byte
	symbol := (^win.SYMBOL_INFOW)(&data[0])
	symbol.SizeOfStruct = size_of(win.SYMBOL_INFOW)
	symbol.MaxNameLen = 255
	if win.SymFromNameW(win.GetCurrentProcess(), wname, symbol) {
		return rawptr(uintptr(symbol.Address))
	}
	return nil
}

// --- near-block scratch: trampolines + import cells --------------------------
//
// Both live within +/-2GB of the loaded block so a REL32 from the loaded code can
// reach them:
//   - trampoline: a resolved external (e.g. ntdll!memcpy) may sit farther than a
//     signed 32-bit displacement from the call site; we route the call through a
//     14-byte absolute jump (`FF 25 00000000; .quad target`).
//   - import cell: a `__imp_X` reference needs a pointer-sized slot holding X's
//     address; there is no such slot for an in-image symbol, so we mint one.
Near_Arena :: struct {
	near:   uintptr,            // allocate within +/-2GB of this (the loaded block)
	block:  rawptr,
	cap:    int,
	used:   int,
	tramps: map[uintptr]rawptr, // target  -> trampoline
	cells:  map[uintptr]rawptr, // address -> import cell holding it
}

@(private)
hr_near_bump :: proc(na: ^Near_Arena, n: int) -> rawptr {
	if na.block == nil || na.used + n > na.cap {
		blk := alloc_near(na.near, 0x1000)
		if blk == nil {
			return nil
		}
		na.block = blk
		na.cap = 0x1000
		na.used = 0
	}
	p := rawptr(uintptr(na.block) + uintptr(na.used))
	na.used += n
	return p
}

@(private)
hr_trampoline_for :: proc(na: ^Near_Arena, target: uintptr) -> rawptr {
	if t, ok := na.tramps[target]; ok {
		return t
	}
	thunk := hr_near_bump(na, 16) // 14 bytes rounded up
	if thunk == nil {
		return nil
	}
	hr_write_abs_jump(([^]u8)(thunk), rawptr(target)) // jmp qword ptr [rip+0]; .quad target
	na.tramps[target] = thunk
	return thunk
}

@(private)
hr_imp_cell :: proc(na: ^Near_Arena, addr: uintptr) -> rawptr {
	if c, ok := na.cells[addr]; ok {
		return c
	}
	cell := hr_near_bump(na, 8)
	if cell == nil {
		return nil
	}
	(^u64)(cell)^ = u64(addr)
	na.cells[addr] = cell
	return cell
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
