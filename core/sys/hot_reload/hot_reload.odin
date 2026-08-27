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
// globals) are resolved against the addresses in the already-running process by
// looking each name up in the exe's PDB (DbgHelp `SymFromNameW`) — no symbol table
// is baked into the exe. A relocation to an existing global resolves to the exe's
// copy, so global state is preserved. The set of `@(hot_reload)` procedures to
// patch is recovered structurally: a hot procedure's running entry is the 2-byte
// MSVC hot-patch slot preceded by a 16-byte patchable-function-prefix pad (see
// `hr_is_hot_entry`), which ordinary prologues never look like.
//
// New symbols across a reload:
//   - New *procedures* called from hot code link automatically (their code lives
//     in the loaded object; callers reach them via relocations).
//   - New *globals* are placed by the compiler into a reserved arena
//     (`__odin_hot_reload_global_arena`) that lives in the exe, so references
//     resolve to stable in-image storage and their state persists across every
//     subsequent reload. New globals are zero-initialized.
//
// Build the exe with `-hot-reload -debug` (and the same `-hot-reload-manifest`) so
// the arena exists and a PDB is present next to the exe; the loader needs the PDB
// to resolve the running exe's symbols. `-hot-reload` requires `-debug`.
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
IMAGE_SCN_MEM_EXECUTE    :: 0x20000000 // section characteristic: executable (code)
IMAGE_SCN_MEM_WRITE      :: 0x80000000 // section characteristic: writable (.data/.bss)

// x64 relocation kinds we handle.
IMAGE_REL_AMD64_ADDR64   :: 0x01
IMAGE_REL_AMD64_ADDR32NB :: 0x03 // 32-bit image-base-relative RVA (.pdata/.xdata unwind)
IMAGE_REL_AMD64_REL32    :: 0x04 // ..= 0x09 for REL32_1 .. REL32_5
IMAGE_REL_AMD64_SECREL :: 0x0B // 32-bit offset of a symbol from the start of its section (TLS access)

COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

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

// One entry of the compiler-emitted `__odin_hot_reload_func_hashes` table: a procedure's
// change-detection hashes. `name_hash` is FNV-1a-64 of the link name (see `hr_fnv64`);
// `content_hash` is a debug-normalized hash of the procedure's code. The loader patches a
// hot procedure only when its `content_hash` differs from the currently-live one. Layout
// must match the C++ emitter (`lb_hot_reload_emit_func_hashes`) in src/llvm_backend.cpp.
Func_Hash :: struct {
	name_hash:    u64,
	content_hash: u64,
}

// FNV-1a-64 over `s` — must match the compiler's `fnv64a` used for `Func_Hash.name_hash`.
@(private)
hr_fnv64 :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(s) {
		h = (h ~ u64(s[i])) * 0x100000001b3
	}
	return h
}

// name_hash -> content_hash of every hot procedure currently LIVE in the process. Seeded
// once from the exe's baseline `__odin_hot_reload_func_hashes` and updated after each
// successful reload, so a reload patches only procedures whose content hash changed.
@(private)
_hr_cur: map[u64]u64
@(private)
_hr_cur_ready: bool

// Read a `__odin_hot_reload_func_hashes` table (layout { i64 count; Func_Hash[count] })
// at `addr` into `dst`. The entries are plain integers (no relocations), so this is valid
// on both the exe's copy (PDB address) and the reload object's mapped copy.
@(private)
hr_read_func_hashes :: proc(addr: rawptr, dst: ^map[u64]u64) {
	if addr == nil {
		return
	}
	count := (^i64)(addr)^
	entries := ([^]Func_Hash)(rawptr(uintptr(addr) + 8))
	for k in 0 ..< int(count) {
		e := entries[k]
		dst[e.name_hash] = e.content_hash
	}
}

// Whether hot procedure `name` should be patched: true iff its incoming content hash
// differs from the currently-live one. Missing hashes (older object, or a name not yet
// tracked) are treated as changed, which is always safe (at worst re-patches unchanged code).
@(private)
hr_proc_changed :: proc(name: string, obj_hashes: map[u64]u64, have_obj_hashes: bool) -> bool {
	if !have_obj_hashes {
		return true
	}
	nh := hr_fnv64(name)
	obj_ch, has_obj := obj_hashes[nh]
	cur, has_cur := _hr_cur[nh]
	if has_obj && has_cur {
		return obj_ch != cur
	}
	return true
}

// Reload `obj_path` into this running process, patching every `@(hot_reload)`
// procedure to its fresh implementation. The set of procedures to patch is
// discovered structurally from the running exe (see `hr_is_hot_entry`), so the
// caller does not have to list them. Returns true if every hot procedure was
// patched. The exe must have been built with `-hot-reload -debug` (a PDB next to
// the exe), which the loader uses to resolve the running exe's symbols.
apply :: proc(obj_path: string) -> bool {
	return load_and_patch(obj_path)
}

// Load `obj_path`, relocate it against this running process, and replace every
// `@(hot_reload)` procedure with its fresh implementation. Returns true if every
// hot procedure was patched.
load_and_patch :: proc(obj_path: string) -> bool {
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

	// Every running-exe address is resolved on demand from the exe's PDB (see
	// `hr_resolve_pdb`, which caches). Discover the `@(hot_reload)` procedures to
	// patch structurally while resolving the object's symbols below (collected into
	// `hot_names`). `tls_cache` memoizes each thread-local's exe TLS-block offset,
	// computed lazily via its accessor when a SECREL relocation first references it.
	if !hr_dbghelp_ensure() {
		fmt.eprintln("[hot] could not initialize DbgHelp; is the exe built with -debug (a PDB next to it)?")
		return false
	}
	hot_names := make([dynamic]string, context.temp_allocator)
	tls_cache := make(map[string]uintptr, context.temp_allocator)

	// Change detection: seed the live-hash baseline from the exe's func-hash table once,
	// then diff this reload object's hashes against it so only procedures whose code
	// changed are patched (unchanged procs — including the whole runtime and this loader —
	// are skipped). If either table is missing (older exe/object), every eligible procedure
	// is treated as changed, matching the pre-change-detection behaviour.
	if !_hr_cur_ready {
		_hr_cur = make(map[u64]u64)
		hr_read_func_hashes(hr_resolve_pdb("__odin_hot_reload_func_hashes"), &_hr_cur)
		_hr_cur_ready = true
	}
	obj_hashes := make(map[u64]u64, context.temp_allocator)
	have_obj_hashes := false // set once the object's table is located (after sections map)

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

	// This reload object's per-procedure content hashes (plain integers, no relocations),
	// for change detection in the resolution loop below.
	if tbl, ok := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, "__odin_hot_reload_func_hashes"); ok {
		hr_read_func_hashes(tbl, &obj_hashes)
		have_obj_hashes = len(obj_hashes) > 0
	}

	// 2) Resolve every symbol slot to a runtime address.
	//    - defined & hot (patchable prologue in exe) -> the object's fresh copy (new code)
	//    - defined & present in the exe (via PDB)     -> the exe's address (reuse / preserve globals)
	//    - defined & object-local                     -> the object's loaded copy (new procs, constants, labels)
	//    - undefined external                         -> the exe's address (PDB / export), else unresolved
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
				exe_addr := hr_resolve_pdb(name)
				// Only a symbol defined in an executable section can be a hot procedure.
				// Restricting the (byte-reading) hot check to code symbols also avoids
				// dereferencing a data global that happens to sit next to an unmapped page.
				sh := section_header(data, sec_off, sn - 1)
				is_code := (u32(sh.characteristics) & IMAGE_SCN_MEM_EXECUTE) != 0
				if exe_addr != nil && is_code && hr_is_hot_entry(exe_addr) && hr_proc_changed(name, obj_hashes, have_obj_hashes) {
					// A hot procedure whose code CHANGED: run this object's fresh copy and
					// redirect the exe's entry to it (patched in step 4).
					resolved[i] = obj_addr
					append(&hot_names, name)
				} else if exe_addr != nil {
					// Pre-existing and unchanged (or a non-hot proc / global): reuse the
					// exe's copy. Global state is preserved, unchanged code is not
					// re-patched, and an unchanged proc whose exe entry is already a
					// trampoline from a prior reload still reaches the current version.
					resolved[i] = exe_addr
				} else {
					// Object-local: a new proc/global, a string constant, a label.
					resolved[i] = obj_addr
				}
			} else if sn == 0 {
				// Undefined external: an Odin symbol (via the exe's PDB), a C-runtime
				// helper / _tls_index / Windows-API export, or an `__imp_` cell.
				resolved[i] = hr_resolve(name, &near_arena)
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
				if off, ok := hr_tls_offset(sname, &tls_cache); ok {
					// Absolute 32-bit section offset + any per-site addend already
					// present (e.g. an array-element index within the variable).
					(^u32)(site)^ = u32(off) + (^u32)(site)^
				} else {
					unresolved += 1
					if is_text {
						unresolved_text += 1
						fmt.eprintfln("[hot] thread-local not resolvable in exe (its accessor __odin_hrtls$%s is not in the exe/PDB): %s", sname, sname)
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
				off := i64(uintptr(target)) - i64(uintptr(block))
				if off < 0 || off + addend < 0 || off + addend > i64(total) {
					// External target: the RVA would wrap. Refuse rather than corrupt the
					// unwind tables (does not arise for Odin unwind data today).
					unresolved += 1
					if is_text { unresolved_text += 1 }
					fmt.eprintln("[hot] ADDR32NB target out of block (RVA would wrap)")
				} else {
					(^u32)(site)^ = u32(off + addend)
				}
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
		if arena_addr := hr_resolve_pdb("__odin_hot_reload_global_arena"); arena_addr != nil {
			count := (^i64)(tbl_addr)^
			entries := ([^]New_Global_Init)(rawptr(uintptr(tbl_addr) + 8))
			for k in 0 ..< int(count) {
				e := entries[k]
				flag := (^u8)(uintptr(arena_addr) + uintptr(e.flag_offset))
				if flag^ == 0 {
					dst := rawptr(uintptr(arena_addr) + uintptr(e.arena_offset))
					intrinsics.mem_copy(dst, e.blob, int(e.size))
					flag^ = 1
				}
			}
		}
	}

	// 3.6) Immutable-data ("refresh") globals — @(rodata) / #load. The compiler lists each
	//      one's {size, link name} in a self-contained blob (no relocations). For every one
	//      that also exists in the exe, repoint the exe's copy at THIS reload's fresh copy:
	//      overwrite `size` bytes exe<-object. For a slice/string/#load global that size is
	//      the 16-byte header, so the exe header comes to point at the object's fresh blob
	//      (which persists in this mapped block) — a data size change is therefore free; a
	//      value-type @(rodata) is overwritten in place. Because the exe's single canonical
	//      copy is updated, ALL code (patched or not) sees the new data. A symbol absent from
	//      the exe is a NEW @(rodata)/#load global — skipped here, since object code already
	//      references its object-local fresh copy. The writes happen under the stop-the-world
	//      below so a reader never sees a torn value.
	Refresh_Target :: struct {
		exe, obj: rawptr,
		size:     int,
	}
	refresh_targets := make([dynamic]Refresh_Target, context.temp_allocator)
	if tbl, ok := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, "__odin_hot_reload_refresh_syms"); ok {
		p := uintptr(tbl)
		count := (^i64)(p)^
		p += 8
		for _ in 0 ..< int(count) {
			size := int((^i64)(p)^); p += 8
			nlen := int((^i64)(p)^); p += 8
			name := string(([^]u8)(rawptr(p))[:nlen]); p += uintptr(nlen)
			exe := hr_resolve_pdb(name)
			obj, found := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, name)
			if exe != nil && found && size > 0 {
				append(&refresh_targets, Refresh_Target{exe, obj, size})
			}
		}
	}

	// 4) Patch each discovered hot procedure's running entry to jump to its fresh code.
	//    `hot_names` were collected in step 2 (an exe symbol whose entry is the
	//    patchable hot-patch prologue). Resolve every original (exe, via the PDB) and
	//    fresh (object) address first, then patch the whole batch with all other
	//    threads suspended and only once no thread is parked in a region we overwrite —
	//    so a concurrent thread never executes a half-written instruction.
	if len(hot_names) == 0 && len(refresh_targets) == 0 {
		if have_obj_hashes {
			// Change detection: no procedure's code changed since the currently-live
			// version and no immutable data to repoint — a valid no-op reload (e.g. only
			// comments changed, or a new proc nothing calls yet). Refresh the baseline.
			for k, v in obj_hashes {
				_hr_cur[k] = v
			}
			fmt.println("[hot] no changed procedures to patch")
			return true
		}
		fmt.eprintln("[hot] no hot-reloadable procedures found in the running exe (build it with -hot-reload -debug)")
		return false
	}
	Target :: struct {
		name:            string,
		original, fresh: rawptr,
	}
	// Resolve and validate EVERY hot target before writing a single byte: patching is
	// not transactional, so a failure discovered mid-batch would leave the program
	// half-patched (some procs new, some old, callers split across two ABIs). If any
	// target cannot be resolved, abort the whole reload with nothing applied.
	targets := make([dynamic]Target, context.temp_allocator)
	for name in hot_names {
		original := hr_resolve_pdb(name) // cached; found in step 2
		fresh, found := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, name)
		if original == nil || !found {
			fmt.eprintfln("[hot] aborting reload: could not resolve hot procedure %q (original=%v, fresh_found=%v); nothing patched", name, original != nil, found)
			return false
		}
		append(&targets, Target{name, original, fresh})
	}
	// (A reload with only immutable-data changes has no proc targets but non-empty
	// refresh_targets; the empty-both case already returned above.)

	// Guard the whole region each patch may touch: the atomic path writes the 16-byte
	// pad BELOW the entry and flips the 2-byte entry; the fallback overwrites PATCH_LEN
	// bytes AT the entry. Cover [entry - PAD_LEN, entry + PATCH_LEN) so a thread parked
	// anywhere the patch writes forces a retry instead of executing a half-written byte.
	regions := make([]Patch_Region, len(targets), context.temp_allocator)
	for t, i in targets {
		lo := uintptr(t.original)
		lo = lo >= PAD_LEN ? lo - PAD_LEN : 0
		regions[i] = Patch_Region{lo, uintptr(t.original) + PATCH_LEN}
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

	// Repoint immutable-data globals now that the world is stopped (no torn reads). Each
	// copy is `size` bytes exe<-object: a slice/string/#load header (16 bytes) starts
	// pointing at the object's fresh blob; a value-type @(rodata) is overwritten in place.
	for r in refresh_targets {
		old: win.DWORD
		if win.VirtualProtect(r.exe, win.SIZE_T(r.size), win.PAGE_READWRITE, &old) {
			intrinsics.mem_copy(r.exe, r.obj, r.size)
			restored: win.DWORD
			win.VirtualProtect(r.exe, win.SIZE_T(r.size), old, &restored)
		} else {
			fmt.eprintfln("[hot] could not make @(rodata)/#load copy writable to refresh it (%d bytes @ %p)", r.size, r.exe)
		}
	}
	if len(refresh_targets) > 0 {
		fmt.printfln("[hot] refreshed %d @(rodata)/#load global(s)", len(refresh_targets))
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

	// 5) Tighten the block from RWX to per-section protections now that all relocations,
	//    refresh copies, and patches are done: executable code -> execute+read; read-only
	//    data (@(rodata)/#load payloads, unwind tables) -> read-only so a stray write faults
	//    as in a normal build; real data (.data/.bss) -> read+write. Sections are page-aligned
	//    in the block (each owns whole pages), so protect them independently. One-shot per
	//    reload (each reload maps a fresh block).
	for i in 0 ..< n_sections {
		if offsets[i + 1] < 0 {
			continue
		}
		sh := section_header(data, sec_off, i)
		base := section_bases[i + 1]
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		if size <= 0 || base == nil {
			continue
		}
		psize := win.SIZE_T(((size + PAGE - 1) / PAGE) * PAGE)
		ch := u32(sh.characteristics)
		prot: win.DWORD = win.PAGE_READONLY
		if (ch & IMAGE_SCN_MEM_EXECUTE) != 0 {
			prot = win.PAGE_EXECUTE_READ
		} else if (ch & IMAGE_SCN_MEM_WRITE) != 0 {
			prot = win.PAGE_READWRITE
		}
		old: win.DWORD
		win.VirtualProtect(base, psize, prot, &old)
	}

	ok := patched == len(targets)
	if ok {
		// The reload object is now the live version: update the change-detection baseline
		// so the next reload diffs against it (patched procs get their new hash; unchanged
		// procs keep theirs; newly added procs are recorded).
		for k, v in obj_hashes {
			_hr_cur[k] = v
		}
	}
	return ok
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

// True iff the 16-byte pad immediately before `entry` is a usable patch pad: still
// the compiler-emitted `patchable-function-prefix` filler (0x90 NOP, or 0xCC if a
// linker also padded), or already holding our own jump (FF 25 ...) from a previous
// reload. `entry` must be at least PAD_LEN into the image.
@(private)
hr_has_patch_pad :: proc(entry: rawptr) -> bool {
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 {
		return true
	}
	for i in 0 ..< PATCH_LEN {
		if pb[i] != 0x90 && pb[i] != 0xCC {
			return false
		}
	}
	return true
}

// True iff the running procedure at `entry` is an `@(hot_reload)` procedure. Such a
// procedure is emitted with the compiler's 16-byte `patchable-function-prefix`
// immediately before its entry, filled with NOPs (0x90). `prologue-short-redirect`
// keeps the entry a normal (>=2 byte) prologue; the redirect lives in that pad. So the
// structural signal is the pad, not the entry bytes: 16 bytes of 0x90 (fresh), or —
// after a previous reload — our own far jump (starts FF 25) written into it. Ordinary
// procedures carry no such 16-byte NOP prefix, and data symbols aren't 0x90-filled, so
// this recovers the hot set from the running exe with no baked table or metadata
// section. Reads only; `entry` is a running-exe address from the PDB (or an object
// copy). NOTE: this is the contract with the compiler (src/llvm_backend_proc.cpp): if
// the prefix size or fill byte changes, update PAD_LEN / this check to match.
@(private)
hr_is_hot_entry :: proc(entry: rawptr) -> bool {
	if uintptr(entry) < PAD_LEN {
		return false
	}
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 { // already redirected by a previous reload
		return true
	}
	for i in 0 ..< PAD_LEN { // fresh: the compiler-emitted NOP prefix
		if pb[i] != 0x90 {
			return false
		}
	}
	return true
}

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
	// Usable iff the pad ahead of the entry is the compiler-emitted
	// `patchable-function-prefix` filler or already holds our own jump from a previous
	// reload; otherwise there is no pad here and we fall back to the prologue overwrite.
	if !hr_has_patch_pad(original) {
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
// resolvable via the exe's PDB (Odin procs/globals): C runtime helpers the backend
// synthesises (`memcpy`/`memset`/`memmove`/`memcmp`), the TLS index `_tls_index`,
// and any Windows-API import. These must resolve to an address
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
//   - direct Odin symbol      -> the exe's PDB (via `hr_resolve_external`)
//   - direct C/OS symbol       -> export lookup, then non-exported in-image set
//   - `__imp_X` (import cell)  -> a synthesised pointer cell holding the address of X
@(private)
hr_resolve :: proc(name: string, na: ^Near_Arena) -> rawptr {
	if p := hr_resolve_external(name); p != nil {
		return p
	}
	// `__imp_X` is an indirection slot the object reads to get X's address. There is
	// no such slot for an in-image/static symbol, so synthesise one near the block.
	IMP :: "__imp_"
	if strings.has_prefix(name, IMP) {
		real := name[len(IMP):]
		if a := hr_resolve_external(real); a != nil {
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

// name -> address for every symbol in the running exe, built once by enumerating the
// exe's PDB (see `hr_dbghelp_ensure`). Exact-match lookups here, NOT `SymFromNameW`:
// Odin link names contain `[file.odin]` brackets, which DbgHelp's by-name lookup
// mis-parses as a wildcard character class and fails to match. Addresses are stable
// within a process run, so this is populated once and kept across reloads.
@(private)
_hr_syms: map[string]rawptr

// State threaded through the SymEnumSymbolsW callback: the map to fill and the Odin
// context to install (the callback is a `proc "system"` with no context of its own).
@(private)
Hr_Enum_State :: struct {
	syms: ^map[string]rawptr,
	ctx:  runtime.Context,
}

@(private)
hr_enum_cb :: proc "system" (pSym: win.PSYMBOL_INFOW, size: win.ULONG, user: win.PVOID) -> win.BOOL {
	st := (^Hr_Enum_State)(user)
	context = st.ctx
	// `Address` is only a virtual address for functions and plain data. For a
	// thread-local it is a TLS-block-relative offset, for register/frame/value
	// symbols it is not an address at all — storing those would poison the map with a
	// small integer masquerading as a pointer. Skip them (thread-locals are resolved
	// via their `__odin_hrtls$<name>` accessor, not by this direct entry).
	NON_ADDR :: win.SYMFLAG_TLSREL | win.SYMFLAG_REGISTER | win.SYMFLAG_REGREL |
	            win.SYMFLAG_FRAMEREL | win.SYMFLAG_VALUEPRESENT | win.SYMFLAG_CONSTANT
	if (u32(pSym.Flags) & NON_ADDR) != 0 {
		return win.TRUE
	}
	n := int(pSym.NameLen)
	if n > 0 {
		wname := ([^]u16)(&pSym.Name[0])
		if name, err := win.utf16_to_utf8(wname[:n], context.allocator); err == nil && len(name) > 0 {
			// Keep the first address seen for a name; ignore later duplicates.
			if _, exists := st.syms[name]; !exists {
				st.syms[name] = rawptr(uintptr(pSym.Address))
			}
		}
	}
	return win.TRUE
}

// Initialize DbgHelp and enumerate the running exe's PDB symbols into `_hr_syms`.
// SymInitialize with fInvadeProcess loads symbols for every currently-loaded module,
// including the exe's PDB. Done once and kept warm across reloads (never SymCleanup'd).
// Returns false if there is no PDB (exe not built with -debug).
@(private)
hr_dbghelp_ensure :: proc() -> bool {
	if _hr_dbghelp_ready {
		// Success is defined as "the exe module's symbols enumerated": a missing or
		// public-only PDB yields an empty map, which must be treated as failure so the
		// loader does not silently resolve everything to fresh object-local copies.
		return len(_hr_syms) > 0
	}
	_hr_dbghelp_ready = true // attempt exactly once; a missing PDB will not appear later
	if !win.SymInitialize(win.GetCurrentProcess(), nil, true) {
		return false
	}
	win.SymSetOptions(win.SYMOPT_DEFERRED_LOADS)
	_hr_syms = make(map[string]rawptr)
	base := win.ULONG64(uintptr(win.GetModuleHandleW(nil))) // the exe's image base
	st := Hr_Enum_State{syms = &_hr_syms, ctx = context}
	// Mask nil -> every symbol in the exe module. Exact names go into the map.
	ok := win.SymEnumSymbolsW(win.GetCurrentProcess(), base, nil, hr_enum_cb, &st)
	if !ok || len(_hr_syms) == 0 {
		// No usable PDB next to the exe (or it carries no private symbols). Every
		// pre-existing symbol would otherwise fail to resolve and be silently
		// duplicated, losing state — so fail loudly instead.
		fmt.eprintfln("[hot] could not enumerate the exe's PDB symbols (SymEnumSymbolsW ok=%v, %d symbols). Build the exe with -hot-reload -debug and keep the .pdb next to it.", ok, len(_hr_syms))
		return false
	}
	return true
}

// Resolve `name` to its address in the running process via the exe's PDB. This is the
// loader's primary symbol resolver: every running procedure and global — Odin symbols,
// preserved globals, the hot procedures being patched, the new-global arena, the
// per-thread-local accessors, and non-exported statically-linked foreign functions —
// is found this way. Requires the exe to have been built with `-debug` (a PDB next to
// it); returns nil otherwise. Lookups are exact against the enumerated symbol map.
@(private)
hr_resolve_pdb :: proc(name: string) -> rawptr {
	if !hr_dbghelp_ensure() {
		return nil
	}
	return _hr_syms[name]
}

// The exe TLS-block offset of the thread-local named `varname`, memoized in `cache`.
// A pre-existing thread-local has no plain address; the compiler emits an accessor
// `__odin_hrtls$<varname>() -> rawptr { return &var }` whose body lowers to the exe's
// TLS access sequence. We find that accessor in the exe's PDB by its (source-stable)
// name, call it to get the variable's per-thread address, and subtract this thread's
// TLS block base — the offset is thread-independent, so computing it on the loader
// thread is valid for every thread. Returns false if the accessor is not in the exe.
@(private)
hr_tls_offset :: proc(varname: string, cache: ^map[string]uintptr) -> (uintptr, bool) {
	if off, ok := cache[varname]; ok {
		return off, true
	}
	base := hr_tls_block_base()
	if base == 0 {
		return 0, false
	}
	acc_name := strings.concatenate({"__odin_hrtls$", varname}, context.temp_allocator)
	acc := hr_resolve_pdb(acc_name)
	if acc == nil {
		return 0, false
	}
	addr := (transmute(proc "c" () -> rawptr) acc)()
	off := uintptr(addr) - base
	cache[varname] = off
	return off, true
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
