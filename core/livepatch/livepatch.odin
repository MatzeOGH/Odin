#+build windows
package livepatch

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"

PAGE :: 0x1000

LP_TIMING :: #config(LP_TIMING, false)

// Bring each reload block into the process as a real SEC_IMAGE section (so a
// debugger attached from the start is notified of the reload) instead of
// VirtualAlloc + hand-copy. See section.odin. Set -define:LP_SECTION_MAP=false to
// force the old VirtualAlloc path.
LP_SECTION_MAP :: #config(LP_SECTION_MAP, true)

@(private) _lp_busy: b32
@(private) _lp_build_busy: b32
// Set once the first reload has swept stale lp_<addr>.dll/.pdb files from prior runs.
@(private) _lp_swept: bool

// A single reload object mapped into memory near the exe, plus the bookkeeping needed to relocate and later free it.
@(private)
Obj :: struct {
	path:          string,
	data:          []byte,
	sec_off:       int,
	sym_off:       int,
	n_syms:        int,
	strtab_off:    int,
	n_sections:    int,
	section_bases: []rawptr,
	offsets:       []int,
	block:         rawptr,
	total:         int,
	dbg_off:       int, // offset within the block of the synthetic debug-dir section
	text_base:     rawptr,
	text_size:     int,
	near_arena:    Near_Arena,
	resolved:      []rawptr,
	pdata_regs:    [dynamic]win.PRUNTIME_FUNCTION,

	// Debug-module state. When `mapped`, `block` is a SEC_IMAGE view (freed via
	// NtUnmapViewOfSection) and the lp_%p.dll/.pdb + PE header + PDB were emitted in
	// lp_map_object before mapping; otherwise `block` is a VirtualAlloc block (freed
	// via VirtualFree) and those artifacts are emitted later in lp_debug_register.
	mapped:        bool,
	size_of_image: u32,
	dbg_nfuncs:    int,
	guid:          [16]u8,
	age:           u32,
	img_path:      string, // "" until the module's files are written
	pdb_path:      string,
	base_name:     string, // e.g. "lp_0x7ff768000000.dll"
	ldr:           ^Lp_Ldr_Entry, // spliced PEB entry (nil until registered)
	sym_loaded:    bool,   // in-process SymLoadModuleExW succeeded
}

@(private)
Hot :: struct {
	name: string,
	obj:  int,
}

// Reads a COFF object, validates it, reserves memory within 2GB of the exe and
// copies its sections in. On failure the caller must abort the reload; the
// half-built Obj is not returned (ok=false).
@(private)
lp_map_object :: proc(path: string) -> (o: Obj, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("[livepatch] could not read object:", path, err)
		return
	}
	if len(data) < FILE_HDR_SIZE {
		fmt.eprintln("[livepatch] object too small:", path)
		return
	}
	hdr := (^Coff_File_Header)(raw_data(data))
	if int(hdr.machine) != IMAGE_FILE_MACHINE_AMD64 {
		fmt.eprintfln("[livepatch] %s: unexpected machine 0x%x (need AMD64)", path, int(hdr.machine))
		return
	}

	o.path       = path
	o.data       = data
	o.n_sections = int(hdr.number_of_sections)
	o.sec_off    = FILE_HDR_SIZE + int(hdr.size_of_optional_header)
	o.sym_off    = int(hdr.pointer_to_symbol_table)
	o.n_syms     = int(hdr.number_of_symbols)
	o.strtab_off = o.sym_off + o.n_syms*COFF_SYMBOL_SIZE

	o.section_bases = make([]rawptr, o.n_sections + 1, context.temp_allocator)
	o.offsets = make([]int, o.n_sections + 1, context.temp_allocator)
	// Reserve the first page for a synthetic PE header (see debug.odin), so the
	// block parses as an image at base `o.block` for an attached debugger. All
	// relocations are block-relative, so this shift is transparent to them.
	total := PAGE
	for i in 0 ..< o.n_sections {
		sh := section_header(data, o.sec_off, i)
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		if size == 0 || lp_is_discarded_section(sh) {
			o.offsets[i + 1] = -1
			continue
		}
		total = mem.align_forward_int(total, PAGE)
		o.offsets[i + 1] = total
		total += size
	}
	total = mem.align_forward_int(total, PAGE)
	// Reserve one more page for a synthetic read-only section that holds the PE
	// debug directory + RSDS record (debug.odin). It must live in a real section
	// so section-based RVA readers (dbghelp/DIA) can find it.
	o.dbg_off = total
	total += PAGE
	o.total = total

	// Preferred path: build the image on disk and map it as a SEC_IMAGE section, so
	// the kernel fires a live LOAD_DLL event for an attached debugger. Falls back to
	// VirtualAlloc when disabled, when the object has no debuggable code, or when no
	// near-exe base is free — in which case the debug module (if any) is emitted the
	// old way in lp_debug_register.
	established := false
	when LP_SECTION_MAP {
		established = lp_establish_section(&o)
	}
	if !established {
		o.block = alloc_near_exe(total)
		if o.block == nil {
			fmt.eprintln("[livepatch] could not reserve memory within 2GB of the exe for", path)
			return
		}
		o.mapped = false
		for i in 0 ..< o.n_sections {
			if o.offsets[i + 1] < 0 {
				continue
			}
			sh := section_header(data, o.sec_off, i)
			if int(sh.size_of_raw_data) > 0 && int(sh.pointer_to_raw_data) != 0 {
				base := rawptr(uintptr(o.block) + uintptr(o.offsets[i + 1]))
				intrinsics.mem_copy(base, raw_data(data[int(sh.pointer_to_raw_data):]), int(sh.size_of_raw_data))
			}
		}
	}

	// Common to both paths: section base pointers + .text (bytes are already in the
	// block — copied above for VirtualAlloc, mapped from the file for a section view).
	for i in 0 ..< o.n_sections {
		if o.offsets[i + 1] < 0 {
			continue
		}
		sh := section_header(data, o.sec_off, i)
		base := rawptr(uintptr(o.block) + uintptr(o.offsets[i + 1]))
		o.section_bases[i + 1] = base
		if section_name(sh) == ".text" {
			o.text_base = base
			o.text_size = int(sh.size_of_raw_data)
		}
	}
	o.near_arena = Near_Arena{
		near   = uintptr(o.block),
		tramps = make(map[uintptr]rawptr, context.temp_allocator),
		cells  = make(map[uintptr]rawptr, context.temp_allocator),
	}
	o.resolved = make([]rawptr, o.n_syms, context.temp_allocator)
	o.pdata_regs = make([dynamic]win.PRUNTIME_FUNCTION, context.temp_allocator)
	return o, true
}

// Builds this object's debug image (PE header + section bytes) on disk and maps it
// as a SEC_IMAGE section at a free near-exe base, so the kernel notifies an attached
// debugger of the reload. Emits the lp_%p.dll and lp_%p.pdb; the in-process DbgHelp
// load and PEB splice happen later (post-commit) in lp_debug_register. Returns false
// (→ VirtualAlloc fallback) when the object has no debuggable code or no base is free.
@(private)
lp_establish_section :: proc(o: ^Obj) -> bool {
	// Local scratch for funcs/PDB/image buffer; persistent bits are heap-owned on o.
	scratch: runtime.Arena
	_ = runtime.arena_init(&scratch, 0, runtime.heap_allocator())
	defer runtime.arena_destroy(&scratch)
	alloc := runtime.arena_allocator(&scratch)

	funcs, files := lp_extract_funcs(o, alloc)
	if len(funcs) == 0 {
		return false // nothing debuggable here → plain VirtualAlloc block, no module
	}
	when #config(LP_DBG_MIN, false) {
		if len(funcs) > 1 { funcs = funcs[:1] }
		if len(files) > 1 { files = files[:1] }
	}

	// Base-independent identity, so a base-conflict retry need not re-emit the PDB.
	age := _lp_dbg_age
	_lp_dbg_age += 1
	_lp_dbg_serial += 1
	guid: [16]u8
	sid := _lp_dbg_serial
	for k in 0 ..< 8 { guid[k] = u8(sid >> uint(k*8)) }
	guid[8] = u8(age); guid[9] = u8(age >> 8)
	guid[10] = 0x4c; guid[11] = 0x50 // 'LP'

	pdb_bytes := lp_emit_pdb(guid, age, funcs, files, lp_sections_for_pdb(o, alloc))
	dir := filepath_dir_of_exe(alloc)
	exe_base := uintptr(win.GetModuleHandleW(nil))

	// Heads-up before the map: mapping the section fires a live LOAD_DLL that makes an
	// attached debugger stop once. Printed here (pre-map) so it is the last console line
	// visible at the stop; once per reload even if several modules map.
	if !_lp_dbg_warned && lp_debugger_present() {
		fmt.println("[livepatch] debugger attached — it may stop when the patched module loads; press Continue to reach the new code.")
		_lp_dbg_warned = true
	}

	skip: uintptr = 0
	for _ in 0 ..< 16 {
		B := lp_find_free_near(exe_base, o.total, skip)
		if B == 0 { break }
		skip = B // a retry searches strictly beyond this candidate

		// Include the monotonic serial so the module and PDB filenames are UNIQUE per
		// reload, never reused. Eager retirement frees the previous block, so the next
		// reload's lp_find_free_near reclaims the same near-exe base — which would make a
		// base-derived name (lp_<base>.dll) reappear every other reload. A debugger caches
		// a PDB by its path+GUID; a reappearing filename serves the stale cached PDB (old
		// GUID) so its symbols no longer match the freshly mapped image and the breakpoint
		// fails on the repeats ("works every other patch"). A serial-stamped name is seen
		// once, so the debugger always loads the current PDB fresh. Base is kept in the
		// name for readability (it still matches the "module at %p" log).
		base_name := fmt.aprintf("lp_%p_g%d.dll", rawptr(B), sid, allocator = alloc)
		pdb_name  := fmt.aprintf("lp_%p_g%d.pdb", rawptr(B), sid, allocator = alloc)
		img_path  := fmt.aprintf("%s\\%s", dir, base_name, allocator = alloc)
		pdb_path  := fmt.aprintf("%s\\%s", dir, pdb_name, allocator = alloc)

		// Assemble the whole image (section bytes + synthetic header) at base B.
		buf := make([]u8, o.total, alloc)
		for i in 0 ..< o.n_sections {
			if o.offsets[i+1] < 0 { continue }
			sh := section_header(o.data, o.sec_off, i)
			if int(sh.size_of_raw_data) > 0 && int(sh.pointer_to_raw_data) != 0 {
				intrinsics.mem_copy(&buf[o.offsets[i+1]], raw_data(o.data[int(sh.pointer_to_raw_data):]), int(sh.size_of_raw_data))
			}
		}
		soi := lp_write_pe_header(o, raw_data(buf), B, guid, age, pdb_path, base_name)

		if !os2_write(img_path, buf) { continue }
		if !os2_write(pdb_path, pdb_bytes) { os.remove(img_path); continue }

		base, ok := lp_section_map(img_path, B)
		if !ok {
			os.remove(img_path); os.remove(pdb_path)
			continue
		}

		o.block         = base
		o.mapped        = true
		o.size_of_image = soi
		o.guid          = guid
		o.age           = age
		o.dbg_nfuncs    = len(funcs)
		o.base_name     = strings.clone(base_name, runtime.heap_allocator())
		o.img_path      = strings.clone(img_path, runtime.heap_allocator())
		o.pdb_path      = strings.clone(pdb_path, runtime.heap_allocator())
		lp_make_sections_writable(o)
		return true
	}
	return false
}

// A SEC_IMAGE view maps code RX and read-only data RO; make every kept section
// writable so relocation, external resolution and patching can write in place. The
// writes fault in private copy-on-write pages; the intended protections are restored
// after patching (see the per-section VirtualProtect at the end of apply_many).
@(private)
lp_make_sections_writable :: proc(o: ^Obj) {
	for i in 0 ..< o.n_sections {
		if o.offsets[i+1] < 0 { continue }
		sh := section_header(o.data, o.sec_off, i)
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		if size <= 0 { continue }
		base := rawptr(uintptr(o.block) + uintptr(o.offsets[i+1]))
		psize := win.SIZE_T(mem.align_forward_int(size, PAGE))
		prot: win.DWORD = win.PAGE_READWRITE
		if (u32(sh.characteristics) & IMAGE_SCN_MEM_EXECUTE) != 0 {
			prot = win.PAGE_EXECUTE_READWRITE
		}
		old: win.DWORD
		win.VirtualProtect(base, psize, prot, &old)
	}
}

// Builds the merged symbol tables across all objects: `all_defs` maps every
// object-defined symbol to its object address, `all_syms` picks the address a
// relocation should target — always a procedure's *stable* cell (its exe entry,
// whose patch pad is the indirection, or the persistent trampoline of a proc the
// reload introduced), never a body address — and `hot_names`/`new_hot` list the
// cells to retarget. Routing every call site through the stable cell is what
// keeps exactly one live version of a procedure: a caller that is itself never
// re-patched still reaches the newest body of everything it calls.
@(private)
lp_build_symbols :: proc(objs: []Obj, obj_hashes: map[u64]u64, have_obj_hashes: bool) -> (all_syms, all_defs: map[string]rawptr, hot_names, new_hot: [dynamic]Hot, hot_detect_misses: int) {
	all_syms = make(map[string]rawptr, context.temp_allocator)
	all_defs = make(map[string]rawptr, context.temp_allocator)
	hot_names = make([dynamic]Hot, context.temp_allocator)
	new_hot = make([dynamic]Hot, context.temp_allocator)
	for &o, oi in objs {
		cursor := 0
		for sym in coff_symbols(o.data, o.sym_off, o.n_syms, &cursor) {
			name := symbol_name(sym, o.data, o.strtab_off)
			sn := int(sym.section_number)
			if sn > 0 && o.section_bases[sn] != nil {
				obj_addr := rawptr(uintptr(o.section_bases[sn]) + uintptr(sym.value))
				sh := section_header(o.data, o.sec_off, sn - 1)
				if !lp_is_object_local(sym, name, sh) {
					if _, seen := all_defs[name]; !seen {
						all_defs[name] = obj_addr
					}
					if _, seen := all_syms[name]; !seen {
						exe_addr := lp_resolve_pdb(name)
						is_code := (u32(sh.characteristics) & IMAGE_SCN_MEM_EXECUTE) != 0
						if exe_addr != nil && is_code {
							// The exe entry is this proc's stable cell: its patch pad
							// holds the indirection, so callers always land on the
							// newest body. Never point a call site at a body directly.
							all_syms[name] = exe_addr
							changed := lp_proc_changed(name, obj_hashes, have_obj_hashes)
							hot := lp_is_hot_entry(exe_addr)
							if changed && hot {
								append(&hot_names, Hot{name, oi})
							} else if !hot && changed && have_obj_hashes && hash.fnv64a(transmute([]byte)name) in obj_hashes {
								hot_detect_misses += 1
							}
						} else if exe_addr != nil {
							all_syms[name] = exe_addr
						} else if is_code && have_obj_hashes && hash.fnv64a(transmute([]byte)name) in obj_hashes {
							// A newly-added procedure: not in the exe, so it has no entry
							// and no patch pad. Give it a stable cell of its own in the
							// persistent arena so it is an independent patch target and
							// every caller, from this reload or an older one, observes a
							// single live version.
							_, existed := _lp_new_tramps[name]
							tramp := lp_new_proc_trampoline(name)
							if tramp == nil {
								all_syms[name] = obj_addr
							} else {
								all_syms[name] = tramp
								if !existed || lp_proc_changed(name, obj_hashes, have_obj_hashes) {
									append(&new_hot, Hot{name, oi})
								}
							}
						} else {
							all_syms[name] = obj_addr
						}
					}
				}
			}
		}
	}
	return
}

// Resolves every symbol referenced by one object, applies its relocations,
// flushes the icache over patched code and registers its .pdata unwind info.
// Returns per-object relocation-failure counts.
@(private)
lp_relocate_object :: proc(o: ^Obj, all_syms: map[string]rawptr, tls_cache: ^map[string]uintptr) -> (unresolved, unsupported, unresolved_text, unsupported_text: int) {
	cursor := 0
	for sym, i in coff_symbols(o.data, o.sym_off, o.n_syms, &cursor) {
		name := symbol_name(sym, o.data, o.strtab_off)
		sn := int(sym.section_number)
		if sn > 0 && o.section_bases[sn] != nil {
			sh := section_header(o.data, o.sec_off, sn - 1)
			if lp_is_object_local(sym, name, sh) {
				o.resolved[i] = rawptr(uintptr(o.section_bases[sn]) + uintptr(sym.value))
			} else {
				o.resolved[i] = all_syms[name]
			}
		} else if sn == 0 {
			if a, ok := all_syms[name]; ok {
				o.resolved[i] = a
			} else {
				o.resolved[i] = lp_resolve(name, &o.near_arena)
			}
		}
	}

	for si in 0 ..< o.n_sections {
		sh := section_header(o.data, o.sec_off, si)
		base := o.section_bases[si + 1]
		if base == nil {
			continue
		}
		is_text := section_name(sh) == ".text"
		nreloc := int(sh.number_of_relocations)
		roff := int(sh.pointer_to_relocations)
		reloc0 := 0
		if (u32(sh.characteristics) & IMAGE_SCN_LNK_NRELOC_OVFL) != 0 && nreloc == 0xFFFF {
			first := (^Coff_Reloc)(raw_data(o.data[roff:]))
			nreloc = int(first.virtual_address)
			reloc0 = 1
		}
		for r in 0 ..< nreloc {
			rel := (^Coff_Reloc)(raw_data(o.data[roff + (reloc0 + r)*RELOC_SIZE:]))

			if int(rel.type) == IMAGE_REL_AMD64_SECREL {
				site := uintptr(base) + uintptr(rel.virtual_address)
				usym := coff_symbol(o.data, o.sym_off, int(rel.symbol_table_index))
				sname := symbol_name(usym, o.data, o.strtab_off)
				if off, ok := lp_tls_offset(sname, tls_cache); ok {
					(^u32)(site)^ = u32(off) + (^u32)(site)^
				} else {
					unresolved += 1
					if is_text {
						unresolved_text += 1
						fmt.eprintfln("[livepatch] thread-local not resolvable in exe (its accessor __odin_lptls$%s is not in the exe/PDB): %s", sname, sname)
					}
				}
				continue
			}

			target := o.resolved[int(rel.symbol_table_index)]
			if target == nil {
				unresolved += 1
				if is_text {
					unresolved_text += 1
					usym := coff_symbol(o.data, o.sym_off, int(rel.symbol_table_index))
					uname := symbol_name(usym, o.data, o.strtab_off)
					fmt.eprintfln("[livepatch] unresolved symbol in executable code: %s", uname)
					fmt.eprintfln("[livepatch]   (its code is not present in the running image. A -livepatch base build emits every procedure of every imported Odin package, so the usual causes are: the symbol comes from a package no package in the base build imports, which is not supported; it is a foreign static-archive function that nothing in the base references (whole-archive its library with -extra-linker-flags:\"/WHOLEARCHIVE:<lib>\"); the base build used -livepatch-no-preload, which limits a reload to procedures the base build already referenced; or the base build had no -debug, leaving no PDB to resolve non-exported symbols.)")
				}
				continue
			}
			site := uintptr(base) + uintptr(rel.virtual_address)
			switch int(rel.type) {
			case IMAGE_REL_AMD64_ADDR64:
				(^u64)(site)^ = (^u64)(site)^ + u64(uintptr(target))
			case IMAGE_REL_AMD64_REL32 ..= IMAGE_REL_AMD64_REL32 + 5:
				extra := i64(int(rel.type) - IMAGE_REL_AMD64_REL32)
				addend := i64((^i32)(site)^)
				next := i64(site) + 4 + extra
				disp := i64(uintptr(target)) + addend - next
				if disp < -0x8000_0000 || disp > 0x7FFF_FFFF {
					final := u64(i64(uintptr(target)) + addend)
					if th := lp_trampoline_for(&o.near_arena, uintptr(final)); th != nil {
						disp = i64(uintptr(th)) - next
					} else if is_text {
						unresolved_text += 1
						fmt.eprintln("[livepatch] could not allocate trampoline for out-of-range target")
					}
				}
				(^i32)(site)^ = i32(disp)
			case IMAGE_REL_AMD64_ADDR32NB:
				local_target := target
				usym := coff_symbol(o.data, o.sym_off, int(rel.symbol_table_index))
				tsn := int(usym.section_number)
				if tsn > 0 && o.section_bases[tsn] != nil {
					local_target = rawptr(uintptr(o.section_bases[tsn]) + uintptr(usym.value))
				}
				addend := i64((^i32)(site)^)
				off := i64(uintptr(local_target)) - i64(uintptr(o.block))
				if off < 0 || off + addend < 0 || off + addend > i64(o.total) {
					unresolved += 1
					if is_text { unresolved_text += 1 }
					fmt.eprintln("[livepatch] ADDR32NB target out of block (RVA would wrap)")
				} else {
					(^u32)(site)^ = u32(off + addend)
				}
			case:
				unsupported += 1
				if is_text {
					unsupported_text += 1
					usym := coff_symbol(o.data, o.sym_off, int(rel.symbol_table_index))
					uname := symbol_name(usym, o.data, o.strtab_off)
					fmt.eprintfln("[livepatch] unsupported relocation type 0x%x in executable code, against %s", int(rel.type), uname)
				}
			}
		}
	}

	if o.text_base != nil {
		win.FlushInstructionCache(win.GetCurrentProcess(), o.text_base, win.SIZE_T(o.text_size))
	}

	for si in 0 ..< o.n_sections {
		sh := section_header(o.data, o.sec_off, si)
		if section_name(sh) != ".pdata" {
			continue
		}
		pbase := o.section_bases[si + 1]
		if pbase == nil {
			continue
		}
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		count := u32(size / size_of(win.RUNTIME_FUNCTION))
		if count > 0 {
			if !win.RtlAddFunctionTable(win.PRUNTIME_FUNCTION(pbase), win.DWORD(count), win.DWORD64(uintptr(o.block))) {
				fmt.eprintln("[livepatch] RtlAddFunctionTable failed; stack traces through hot code may be wrong")
			} else {
				append(&o.pdata_regs, win.PRUNTIME_FUNCTION(pbase))
			}
		}
	}
	return
}

// A global introduced by this reload, resolved to its persistent storage. `fresh` marks
// the globals this reload allocated for the first time, so their initializer runs once.
@(private)
New_Global :: struct {
	name:    string,
	storage: rawptr,
	size:    int,
	fresh:   bool,
}

// Reads the reload's `__odin_livepatch_new_globals` table (a raw {u64 count, {u64 size,
// u64 name_len, name}...} blob), resolves each new global to persistent near-exe storage,
// and registers it in `all_syms` so the object's relocations reach it. Must run before
// relocation. The table carries no pointers, so it is readable before relocation.
@(private)
lp_prepare_new_globals :: proc(objs: []Obj, all_syms: ^map[string]rawptr) -> []New_Global {
	tbl: rawptr
	for &o in objs {
		if a, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_livepatch_new_globals"); ok {
			tbl = a
			break
		}
	}
	if tbl == nil {
		return nil
	}
	p := uintptr(tbl)
	count := int((^u64)(p)^); p += size_of(u64)
	out := make([dynamic]New_Global, 0, count, context.temp_allocator)
	for _ in 0 ..< count {
		size := int((^u64)(p)^); p += size_of(u64)
		nlen := int((^u64)(p)^); p += size_of(u64)
		name := string(([^]u8)(rawptr(p))[:nlen]); p += uintptr(nlen)
		storage, fresh := lp_new_global_storage(name, size)
		if storage != nil {
			all_syms[name] = storage
			append(&out, New_Global{name, storage, size, fresh})
		}
	}
	return out[:]
}

// Runs each freshly-allocated new global's one-time constant initializer, copying the
// bytes from its `__odin_lpg_init$<name>` blob (a defined symbol in the reload object, so
// its address is in `all_defs`). Must run after relocation: an initializer may embed a
// pointer (e.g. a string literal) that relocation fixes up in place. A global with no
// constant initializer has no blob and keeps its zero-initialized storage.
@(private)
lp_init_new_globals :: proc(ngs: []New_Global, all_defs: map[string]rawptr) {
	for ng in ngs {
		if !ng.fresh {
			continue
		}
		blob_name := strings.concatenate({"__odin_lpg_init$", ng.name}, context.temp_allocator)
		if blob, ok := all_defs[blob_name]; ok && blob != nil {
			intrinsics.mem_copy(ng.storage, blob, ng.size)
		}
	}
}

// Loads, relocates, and hot-patches one or more reload objects into the running process — the core reload routine.
apply_many :: proc(obj_paths: []string) -> bool {
	when !ODIN_LIVEPATCH { return false }
	if _, swapped := intrinsics.atomic_compare_exchange_strong(&_lp_busy, false, true); !swapped {
		fmt.eprintln("[livepatch] a reload is already in progress")
		return false
	}
	defer intrinsics.atomic_store(&_lp_busy, false)

	start := time.tick_now()
	defer fmt.printfln("[livepatch] apply_many took %v", time.tick_since(start))

	mark := start
	// Prints how long a reload phase took, when LP_TIMING is enabled.
	lp_phase :: proc(name: string, mark: ^time.Tick) {
		when LP_TIMING {
			now := time.tick_now()
			fmt.printfln("[livepatch]   %-8s %v", name, time.tick_since(mark^))
			mark^ = now
		}
	}

	scratch: runtime.Arena
	_ = runtime.arena_init(&scratch, 0, runtime.heap_allocator())
	context.temp_allocator = runtime.arena_allocator(&scratch)
	defer runtime.arena_destroy(&scratch)

	_lp_dbg_warned = false // one debugger heads-up per reload (see lp_establish_section)

	// Before emitting this run's first debug module, clear stale lp_<addr>.dll/.pdb
	// files that earlier runs left next to the exe (their last live generation is
	// never retired, and fresh base addresses give fresh names, so they accumulate).
	if !_lp_swept {
		lp_sweep_stale_debug_files()
		_lp_swept = true
	}

	if len(obj_paths) == 0 {
		fmt.eprintln("[livepatch] apply_many: no objects given")
		return false
	}

	if !lp_dbghelp_ensure() {
		fmt.eprintln("[livepatch] could not initialize DbgHelp; is the exe built with -debug (a PDB next to it)?")
		return false
	}

	if !_lp_cur_ready {
		_lp_cur = make(map[u64]u64, runtime.heap_allocator())
		lp_read_func_hashes(lp_resolve_pdb("__odin_livepatch_func_hashes"), &_lp_cur)
		_lp_cur_ready = true
	}
	lp_phase("dbghelp", &mark)

	objs := make([dynamic]Obj, 0, len(obj_paths), context.temp_allocator)

	committed := false
	defer if !committed {
		for &o in objs {
			for p in o.pdata_regs {
				win.RtlDeleteFunctionTable(p)
			}
			if o.block != nil {
				// Pre-commit, no PEB splice / SymLoad has happened yet (those run in
				// lp_debug_register, post-commit); a section block's live LOAD_DLL fired
				// at map time, so unmapping it delivers the matching UNLOAD_DLL.
				if o.mapped {
					lp_section_unmap(o.block)
					if o.img_path != "" { os.remove(o.img_path) }
					if o.pdb_path != "" { os.remove(o.pdb_path) }
				} else {
					win.VirtualFree(o.block, 0, win.MEM_RELEASE)
				}
			}
			if o.near_arena.block != nil {
				win.VirtualFree(o.near_arena.block, 0, win.MEM_RELEASE)
			}
		}
	}

	for path in obj_paths {
		o, ok := lp_map_object(path)
		if !ok {
			return false
		}
		append(&objs, o)
	}
	lp_phase("read", &mark)

	obj_hashes := make(map[u64]u64, context.temp_allocator)
	have_obj_hashes := false
	for &o in objs {
		if tbl, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_livepatch_func_hashes"); ok {
			lp_read_func_hashes(tbl, &obj_hashes)
			have_obj_hashes = len(obj_hashes) > 0
			break
		}
	}

	if exe_bid := lp_resolve_pdb("__odin_livepatch_build_id"); exe_bid != nil {
		for &o in objs {
			if obj_bid, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_livepatch_build_id"); ok {
				exe_id := (^u64)(exe_bid)^
				obj_id := (^u64)(obj_bid)^
				if exe_id != obj_id {
					fmt.eprintfln("[livepatch] build-id mismatch: reload object %s (%d) was not built against the running exe (%d). Rebuild the reload objects against the current exe.", o.path, obj_id, exe_id)
					return false
				}
				break
			}
		}
	}

	all_syms, all_defs, hot_names, new_hot, hot_detect_misses := lp_build_symbols(objs[:], obj_hashes, have_obj_hashes)

	if hot_detect_misses > 0 {
		fmt.eprintfln("[livepatch] WARNING: %d changed livepatchable procedure(s) exist in the running exe but their prologue did not match a patch pad. These procedures were NOT patched.", hot_detect_misses)
	}
	lp_phase("symbols", &mark)

	// Give every global this reload introduces its persistent storage and register it in
	// all_syms before relocation, so the objects' data references resolve to it.
	new_globals := lp_prepare_new_globals(objs[:], &all_syms)

	unresolved, unsupported := 0, 0
	unresolved_text, unsupported_text := 0, 0
	tls_cache := make(map[string]uintptr, context.temp_allocator)
	for &o in objs {
		u, us, ut, ust := lp_relocate_object(&o, all_syms, &tls_cache)
		unresolved += u
		unsupported += us
		unresolved_text += ut
		unsupported_text += ust
	}
	if unresolved > 0 || unsupported > 0 {
		fmt.eprintfln("[livepatch] note: %d unresolved and %d unsupported relocations (fine if only in code you don't call)", unresolved, unsupported)
	}
	// Either kind leaves a call site holding its raw addend, so patching a proc
	// built from it would put silently wrong code live.
	if unresolved_text > 0 || unsupported_text > 0 {
		fmt.eprintfln("[livepatch] aborting reload: %d unresolved and %d unsupported relocation(s) in executable code (see names above)", unresolved_text, unsupported_text)
		return false
	}
	lp_phase("reloc", &mark)

	// Relocation is done, so any pointer an initializer embeds is now fixed up: run each
	// new global's one-time constant initializer into its freshly-allocated storage.
	lp_init_new_globals(new_globals, all_defs)

	meta_i := -1
	for &o, oi in objs {
		if _, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_livepatch_func_hashes"); ok {
			meta_i = oi
			break
		}
	}

	pre_tbl := lp_resolve_pdb("__odin_livepatch_pre_patch_hooks")
	post_tbl: rawptr
	changed: []Type_Change
	needs_swap_types := false
	fresh_ti_hdr: rawptr
	obj_type_hash: u64
	have_obj_type_hash := false
	if meta_i >= 0 {
		mo := &objs[meta_i]
		post_tbl, _ = find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_livepatch_post_patch_hooks")
		if !_lp_cur_type_hash_ready {
			if a := lp_resolve_pdb("__odin_livepatch_type_table_hash"); a != nil {
				_lp_cur_type_hash = (^u64)(a)^
				_lp_cur_type_hash_ready = true
			}
		}
		if a, ok := find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_livepatch_type_table_hash"); ok {
			obj_type_hash = (^u64)(a)^
			have_obj_type_hash = true
		}
		skip_type_walk := _lp_cur_type_hash_ready && have_obj_type_hash && obj_type_hash == _lp_cur_type_hash

		if !skip_type_walk {
			want_changes := lp_hook_count(pre_tbl) > 0 || lp_hook_count(post_tbl) > 0
			needs_swap_types, changed, fresh_ti_hdr = lp_analyze_types(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, want_changes)
		}
	}
	lp_phase("types", &mark)
	defer delete(changed)
	lp_call_patch_hooks(pre_tbl, changed, lp_resolve_pre_hook, nil)

	Refresh_Target :: struct {
		exe, obj: rawptr,
		size:     int,
	}
	refresh_targets := make([dynamic]Refresh_Target, context.temp_allocator)
	if meta_i >= 0 {
		mo := &objs[meta_i]
		if tbl, ok := find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_livepatch_refresh_syms"); ok {
			p := uintptr(tbl)
			count := (^i64)(p)^
			p += size_of(i64)
			for _ in 0 ..< int(count) {
				size := int((^i64)(p)^); p += size_of(i64)
				nlen := int((^i64)(p)^); p += size_of(i64)
				name := string(([^]u8)(rawptr(p))[:nlen]); p += uintptr(nlen)
				exe := lp_resolve_pdb(name)
				obj, found := all_defs[name]
				if exe != nil && found && size > 0 {
					append(&refresh_targets, Refresh_Target{exe, obj, size})
				}
			}
		}
	}

	swap_type_table := false
	tt_ref: rawptr
	if needs_swap_types && fresh_ti_hdr != nil {
		if ref := lp_resolve_pdb("__odin_livepatch_type_table_ref"); ref != nil {
			tt_ref = (^rawptr)(ref)^
		} else {
			tt_ref = lp_resolve_pdb(LP_TYPE_TABLE_SYM)
		}
		swap_type_table = tt_ref != nil
	}

	if len(hot_names) == 0 && len(new_hot) == 0 && len(refresh_targets) == 0 && !swap_type_table {
		lp_call_patch_hooks(post_tbl, changed, lp_resolve_post_hook, &all_defs)
		if have_obj_hashes {
			for k, v in obj_hashes {
				_lp_cur[k] = v
			}
			fmt.println("[livepatch] no changed procedures to patch")
			return true
		}
		fmt.eprintln("[livepatch] no livepatchable procedures found in the running exe (build it with -livepatch -debug)")
		return false
	}
	Target :: struct {
		name:            string,
		original, fresh: rawptr,
	}
	targets := make([dynamic]Target, context.temp_allocator)
	for h in hot_names {
		original := lp_resolve_pdb(h.name)
		// all_defs, not all_syms: all_syms[name] is now the entry itself, and
		// patching an entry to jump to itself would spin.
		fresh, found := all_defs[h.name]
		if original == nil || !found {
			fmt.eprintfln("[livepatch] aborting reload: could not resolve hot procedure %q (original=%v, fresh_found=%v). nothing patched", h.name, original != nil, found)
			return false
		}
		if !lp_has_patch_pad(original) {
			gap := lp_next_symbol_after(uintptr(original)) - uintptr(original)
			if gap < PATCH_LEN {
				fmt.eprintfln("[livepatch] aborting reload: hot procedure %q has no patch pad and only %d bytes to its next symbol (need %d). nothing patched", h.name, gap, PATCH_LEN)
				return false
			}
		}
		append(&targets, Target{h.name, original, fresh})
	}

	// Newly-added procedures: (re)point each stable trampoline at this reload's body.
	New_Target :: struct {
		name:         string,
		tramp, fresh: rawptr,
	}
	new_targets := make([dynamic]New_Target, context.temp_allocator)
	for h in new_hot {
		tramp := lp_new_proc_trampoline(h.name)
		fresh, found := all_defs[h.name]
		if tramp == nil || !found {
			fmt.eprintfln("[livepatch] aborting reload: could not resolve new procedure %q (tramp=%v, fresh_found=%v). nothing patched", h.name, tramp != nil, found)
			return false
		}
		append(&new_targets, New_Target{h.name, tramp, fresh})
	}

	regions := make([]Lp_Range, len(targets), context.temp_allocator)
	for t, i in targets {
		lo := uintptr(t.original)
		lo = lo >= PAD_LEN ? lo - PAD_LEN : 0
		regions[i] = Lp_Range{lo, uintptr(t.original) + PATCH_LEN}
	}
	lp_phase("meta", &mark)

	owner_bound := len(refresh_targets) + len(targets) + len(new_targets) + 1
	_lp_serial += 1
	gen_serial := _lp_serial
	gen_owned := make([dynamic]uintptr, 0, owner_bound, runtime.heap_allocator())
	reserve(&_lp_owner, len(_lp_owner) + owner_bound)
	freeable := make([]bool, len(_lp_generations), context.temp_allocator)

	MAX_ATTEMPTS :: 100
	handles: [dynamic]win.HANDLE
	for attempt := 0; ; attempt += 1 {
		handles = lp_suspend_other_threads()
		if !lp_ip_conflicts(handles, regions) {
			break
		}
		lp_resume(handles)
		if attempt + 1 >= MAX_ATTEMPTS {
			fmt.eprintfln("[livepatch] aborting reload: a thread stayed inside a procedure prologue for %d attempts", MAX_ATTEMPTS)
			return false
		}
		win.Sleep(1)
	}
	lp_phase("suspend", &mark)

	// Pre-flight: flip every destination page writable BEFORE writing a single byte.
	// Threads are suspended and nothing is written yet, so if any VirtualProtect fails we
	// restore whatever we changed, resume, and abort with the running code untouched. Once
	// every region is writable the commit below is pure memory writes that cannot fail, so
	// the reload is all-or-nothing: no thread ever observes a partially applied patch set.
	plans := make([dynamic]Patch_Plan, 0, len(targets), context.temp_allocator)
	refresh_preps := make([dynamic]Wr_Prep, 0, len(refresh_targets), context.temp_allocator)
	tt_prep: Wr_Prep
	preflight_ok := true

	for t in targets {
		plan, ok := lp_patch_prepare(t.original, t.fresh)
		if !ok {
			preflight_ok = false
			break
		}
		append(&plans, plan)
	}
	if preflight_ok {
		for r in refresh_targets {
			w, ok := lp_make_writable(r.exe, r.obj, r.size)
			if !ok {
				fmt.eprintfln("[livepatch] could not make @(rodata)/#load copy writable to refresh it (%d bytes @ %p)", r.size, r.exe)
				preflight_ok = false
				break
			}
			append(&refresh_preps, w)
		}
	}
	if preflight_ok && swap_type_table {
		SLICE_HDR :: size_of(rawptr) + size_of(int)
		w, ok := lp_make_writable(tt_ref, fresh_ti_hdr, SLICE_HDR)
		if !ok {
			fmt.eprintln("[livepatch] could not make runtime.type_table writable to refresh reflection")
			preflight_ok = false
		} else {
			tt_prep = w
		}
	}

	if !preflight_ok {
		for p in plans { lp_patch_restore(p) }
		for w in refresh_preps { lp_restore_writable(w) }
		lp_restore_writable(tt_prep)
		lp_resume(handles)
		fmt.eprintln("[livepatch] aborting reload: could not make a patch target writable; nothing patched")
		return false
	}
	lp_phase("preflight", &mark)

	// Commit: every page is writable, so nothing from here can fail.
	committed = true

	for w in refresh_preps {
		lp_write_region(w)
		_lp_owner[uintptr(w.dst)] = gen_serial
		append(&gen_owned, uintptr(w.dst))
	}
	did_swap := false
	if tt_prep.ok {
		lp_write_region(tt_prep)
		_lp_owner[uintptr(tt_prep.dst)] = gen_serial
		append(&gen_owned, uintptr(tt_prep.dst))
		did_swap = true
	}
	patch_atomic := make([]bool, len(plans), context.temp_allocator)
	for p, i in plans {
		patch_atomic[i] = lp_patch_commit(p)
		_lp_owner[uintptr(p.original)] = gen_serial
		append(&gen_owned, uintptr(p.original))
	}
	patched := len(plans)

	// Restore the intended page protections now that every write is done.
	for w in refresh_preps { lp_restore_writable(w) }
	lp_restore_writable(tt_prep)
	for p in plans { lp_patch_restore(p) }

	// Point each new procedure's stable trampoline at this reload's body. The
	// trampoline arena is permanently writable+executable, and every other thread
	// is suspended, so overwriting all 14 bytes is safe (the stub is a single
	// instruction, so a parked thread's RIP can only be at its first byte, and it
	// resumes into the freshly written absolute jump).
	for t in new_targets {
		lp_write_abs_jump(([^]u8)(t.tramp), t.fresh)
		win.FlushInstructionCache(win.GetCurrentProcess(), t.tramp, win.SIZE_T(PATCH_LEN))
		_lp_owner[uintptr(t.tramp)] = gen_serial
		append(&gen_owned, uintptr(t.tramp))
	}

	// Scan for retire-able generations AFTER _lp_owner reflects this reload's writes,
	// while threads are still suspended. Scanning earlier (before the owner map is
	// updated) left the immediately-previous generation looking "referenced" by its own
	// now-superseded addresses, so it wasn't retired until the NEXT reload — a one-reload
	// lag that kept the previous patch's debug module mapped and spliced alongside the
	// current one. A debugger then saw two modules claiming the same source line and kept
	// its breakpoint bound to the older (dead) one instead of the just-loaded patch. With
	// the scan here, gen N-1 retires during reload N (its lp_<addr>.dll unmaps → the
	// debugger drops the stale binding and rebinds to the live module), leaving only the
	// newest patch module loaded and PEB-spliced.
	lp_scan_freeable(handles, freeable)
	lp_phase("freegen", &mark)

	lp_resume(handles)
	lp_free_marked(freeable)

	if len(refresh_preps) > 0 {
		fmt.printfln("[livepatch] refreshed %d @(rodata)/#load global(s)", len(refresh_preps))
	}
	if did_swap {
		fmt.println("[livepatch] refreshed reflection type_table (edited/new types now visible)")
	}
	for t, i in targets {
		fmt.printfln("[livepatch] patched %s: %p -> %p (%s)", t.name, t.original, t.fresh, patch_atomic[i] ? "atomic" : "overwrite")
	}
	for t in new_targets {
		fmt.printfln("[livepatch] linked new %s: trampoline %p -> %p", t.name, t.tramp, t.fresh)
	}
	for &o in objs {
		for i in 0 ..< o.n_sections {
			if o.offsets[i + 1] < 0 {
				continue
			}
			sh := section_header(o.data, o.sec_off, i)
			base := o.section_bases[i + 1]
			size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
			if size <= 0 || base == nil {
				continue
			}
			psize := win.SIZE_T(mem.align_forward_int(size, PAGE))
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
	}
	// Make each mapped block a debugger-visible module (best-effort).
	when #config(LP_DBGREG, true) {
		for &o in objs {
			lp_debug_register(&o)
		}
	}
	// Reached only on the committed path (an abort returns earlier); prints only when the
	// heads-up did, so the user knows the Continue landed them on patched code.
	if _lp_dbg_warned {
		fmt.println("[livepatch] reload live — patched code is now source-debuggable.")
	}
	lp_phase("patch", &mark)

	if did_swap {
		lp_advance_live_types(fresh_ti_hdr)
		if have_obj_type_hash {
			_lp_cur_type_hash = obj_type_hash
			_lp_cur_type_hash_ready = true
		}
	}

	// The reload is committed: these blocks hold live code and data the process is
	// already reaching, whether or not every entry took. Record the generation
	// before any early-out, otherwise a partial patch strands the blocks, the near
	// arena and the .pdata registrations where retirement can never reach them.
	{
		gen: Lp_Generation
		gen.serial = gen_serial
		gen.owned  = gen_owned
		gen.blocks = make([dynamic]rawptr, runtime.heap_allocator())
		gen.objs   = make([dynamic]Lp_Obj_Res, runtime.heap_allocator())
		gen.pdata  = make([dynamic]win.PRUNTIME_FUNCTION, runtime.heap_allocator())
		gen.ranges = make([dynamic]Lp_Range, runtime.heap_allocator())
		for &o in objs {
			if o.block != nil {
				append(&gen.objs, Lp_Obj_Res{
					block    = o.block,
					mapped   = o.mapped,
					ldr      = o.ldr,
					sym_base = o.sym_loaded ? u64(uintptr(o.block)) : 0,
					img_path = o.img_path,
					pdb_path = o.pdb_path,
				})
				append(&gen.ranges, Lp_Range{uintptr(o.block), uintptr(o.block) + uintptr(o.total)})
			}
			if o.near_arena.block != nil {
				append(&gen.blocks, o.near_arena.block)
				append(&gen.ranges, Lp_Range{uintptr(o.near_arena.block), uintptr(o.near_arena.block) + uintptr(o.near_arena.cap)})
			}
			for p in o.pdata_regs {
				append(&gen.pdata, p)
			}
		}
		if _lp_generations == nil {
			_lp_generations = make([dynamic]Lp_Generation, runtime.heap_allocator())
		}
		append(&_lp_generations, gen)
	}

	// Something went live, so state migration has to run: the app is executing the new
	// code either way. The pre-flight guarantees the patch set applied in full (or the
	// reload aborted before committing a byte), so there is no partial-patch case here.
	if patched > 0 || did_swap || len(refresh_preps) > 0 {
		lp_call_patch_hooks(post_tbl, changed, lp_resolve_post_hook, &all_defs)
	}

	for k, v in obj_hashes {
		_lp_cur[k] = v
	}
	return true
}
