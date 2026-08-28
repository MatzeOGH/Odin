#+build windows
package livepatch

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:time"
import win "core:sys/windows"

PAGE :: 0x1000

LP_TIMING :: #config(LP_TIMING, false)

@(private) _lp_busy: b32
@(private) _lp_build_busy: b32

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
	text_base:     rawptr,
	text_size:     int,
	near_arena:    Near_Arena,
	resolved:      []rawptr,
	pdata_regs:    [dynamic]win.PRUNTIME_FUNCTION,
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
	total := 0
	for i in 0 ..< o.n_sections {
		sh := section_header(data, o.sec_off, i)
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		if size == 0 {
			o.offsets[i + 1] = -1
			continue
		}
		total = mem.align_forward_int(total, PAGE)
		o.offsets[i + 1] = total
		total += size
	}
	total = mem.align_forward_int(total, PAGE)
	o.total = total

	o.block = alloc_near_exe(total)
	if o.block == nil {
		fmt.eprintln("[livepatch] could not reserve memory within 2GB of the exe for", path)
		return
	}
	for i in 0 ..< o.n_sections {
		if o.offsets[i + 1] < 0 {
			continue
		}
		sh := section_header(data, o.sec_off, i)
		base := rawptr(uintptr(o.block) + uintptr(o.offsets[i + 1]))
		o.section_bases[i + 1] = base
		if int(sh.size_of_raw_data) > 0 && int(sh.pointer_to_raw_data) != 0 {
			intrinsics.mem_copy(base, raw_data(data[int(sh.pointer_to_raw_data):]), int(sh.size_of_raw_data))
		}
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

// Builds the merged symbol tables across all objects: `all_defs` maps every
// object-defined symbol to its object address, `all_syms` picks the address a
// relocation should target (the exe's copy, unless the proc is hot & changed),
// and `hot_names` lists the procedures to patch.
@(private)
lp_build_symbols :: proc(objs: []Obj, obj_hashes: map[u64]u64, have_obj_hashes: bool) -> (all_syms, all_defs: map[string]rawptr, hot_names: [dynamic]Hot, hot_detect_misses: int) {
	all_syms = make(map[string]rawptr, context.temp_allocator)
	all_defs = make(map[string]rawptr, context.temp_allocator)
	hot_names = make([dynamic]Hot, context.temp_allocator)
	for &o, oi in objs {
		cursor := 0
		for sym in coff_symbols(o.data, o.sym_off, o.n_syms, &cursor) {
			name := symbol_name(sym, o.data, o.strtab_off)
			sn := int(sym.section_number)
			if sn > 0 && o.section_bases[sn] != nil {
				obj_addr := rawptr(uintptr(o.section_bases[sn]) + uintptr(sym.value))
				sh := section_header(o.data, o.sec_off, sn - 1)
				if !lp_is_object_local_const(sh) {
					if _, seen := all_defs[name]; !seen {
						all_defs[name] = obj_addr
					}
					if _, seen := all_syms[name]; !seen {
						exe_addr := lp_resolve_pdb(name)
						is_code := (u32(sh.characteristics) & IMAGE_SCN_MEM_EXECUTE) != 0
						if exe_addr != nil && is_code {
							changed := lp_proc_changed(name, obj_hashes, have_obj_hashes)
							hot := lp_is_hot_entry(exe_addr)
							if changed && hot {
								all_syms[name] = obj_addr
								append(&hot_names, Hot{name, oi})
							} else {
								if !hot && changed && have_obj_hashes && hash.fnv64a(transmute([]byte)name) in obj_hashes {
									hot_detect_misses += 1
								}
								all_syms[name] = exe_addr
							}
						} else if exe_addr != nil {
							all_syms[name] = exe_addr
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
lp_relocate_object :: proc(o: ^Obj, all_syms: map[string]rawptr, tls_cache: ^map[string]uintptr) -> (unresolved, unsupported, unresolved_text: int) {
	cursor := 0
	for sym, i in coff_symbols(o.data, o.sym_off, o.n_syms, &cursor) {
		name := symbol_name(sym, o.data, o.strtab_off)
		sn := int(sym.section_number)
		if sn > 0 && o.section_bases[sn] != nil {
			sh := section_header(o.data, o.sec_off, sn - 1)
			if lp_is_object_local_const(sh) {
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
					fmt.eprintfln("[livepatch]   (if this is a foreign-library function: its code is not present in the running image. Reference it once in the base build, or link the archive whole, e.g. /WHOLEARCHIVE. Adding a library not linked into the base build is not supported. A base build without -debug also has no PDB to resolve non-exported symbols.)")
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
				win.VirtualFree(o.block, 0, win.MEM_RELEASE)
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

	all_syms, all_defs, hot_names, hot_detect_misses := lp_build_symbols(objs[:], obj_hashes, have_obj_hashes)

	if hot_detect_misses > 0 {
		fmt.eprintfln("[livepatch] WARNING: %d changed livepatchable procedure(s) exist in the running exe but their prologue did not match a patch pad. These procedures were NOT patched.", hot_detect_misses)
	}
	lp_phase("symbols", &mark)

	unresolved, unsupported := 0, 0
	unresolved_text := 0
	tls_cache := make(map[string]uintptr, context.temp_allocator)
	for &o in objs {
		u, us, ut := lp_relocate_object(&o, all_syms, &tls_cache)
		unresolved += u
		unsupported += us
		unresolved_text += ut
	}
	if unresolved > 0 || unsupported > 0 {
		fmt.eprintfln("[livepatch] note: %d unresolved and %d unsupported relocations (fine if only in code you don't call)", unresolved, unsupported)
	}
	if unresolved_text > 0 {
		fmt.eprintfln("[livepatch] aborting reload: %d unresolved relocation(s) in executable code (see names above)", unresolved_text)
		return false
	}
	lp_phase("reloc", &mark)

	meta_i := -1
	for &o, oi in objs {
		if _, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_livepatch_func_hashes"); ok {
			meta_i = oi
			break
		}
	}

	if meta_i >= 0 {
		mo := &objs[meta_i]
		if tbl_addr, ok := find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_livepatch_new_global_inits"); ok {
			if arena_addr := lp_resolve_pdb("__odin_livepatch_global_arena"); arena_addr != nil {
				count := (^i64)(tbl_addr)^
				entries := ([^]New_Global_Init)(rawptr(uintptr(tbl_addr) + size_of(i64)))
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

	if len(hot_names) == 0 && len(refresh_targets) == 0 && !swap_type_table {
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
		fresh, found := all_syms[h.name]
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

	regions := make([]Lp_Range, len(targets), context.temp_allocator)
	for t, i in targets {
		lo := uintptr(t.original)
		lo = lo >= PAD_LEN ? lo - PAD_LEN : 0
		regions[i] = Lp_Range{lo, uintptr(t.original) + PATCH_LEN}
	}
	lp_phase("meta", &mark)

	owner_bound := len(refresh_targets) + len(targets) + 1
	_lp_serial += 1
	gen_serial := _lp_serial
	gen_owned := make([dynamic]uintptr, 0, owner_bound, runtime.heap_allocator())
	reserve(&_lp_owner, len(_lp_owner) + owner_bound)
	freeable := make([]bool, len(_lp_generations), context.temp_allocator)
	refresh_ok := make([]bool, len(refresh_targets), context.temp_allocator)
	patch_ok := make([]bool, len(targets), context.temp_allocator)
	patch_atomic := make([]bool, len(targets), context.temp_allocator)

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

	lp_scan_freeable(handles, freeable)
	lp_phase("freegen", &mark)

	committed = true

	for r, i in refresh_targets {
		old: win.DWORD
		if win.VirtualProtect(r.exe, win.SIZE_T(r.size), win.PAGE_READWRITE, &old) {
			intrinsics.mem_copy(r.exe, r.obj, r.size)
			restored: win.DWORD
			win.VirtualProtect(r.exe, win.SIZE_T(r.size), old, &restored)
			_lp_owner[uintptr(r.exe)] = gen_serial
			append(&gen_owned, uintptr(r.exe))
			refresh_ok[i] = true
		}
	}

	did_swap := false
	if swap_type_table {
		SLICE_HDR :: size_of(rawptr) + size_of(int)
		old: win.DWORD
		if win.VirtualProtect(tt_ref, win.SIZE_T(SLICE_HDR), win.PAGE_READWRITE, &old) {
			intrinsics.mem_copy(tt_ref, fresh_ti_hdr, SLICE_HDR)
			restored: win.DWORD
			win.VirtualProtect(tt_ref, win.SIZE_T(SLICE_HDR), old, &restored)
			_lp_owner[uintptr(tt_ref)] = gen_serial
			append(&gen_owned, uintptr(tt_ref))
			did_swap = true
		}
	}

	patched := 0
	for t, i in targets {
		ok, atomic := patch_jump(t.original, t.fresh)
		if ok {
			patch_ok[i] = true
			patch_atomic[i] = atomic
			patched += 1
			_lp_owner[uintptr(t.original)] = gen_serial
			append(&gen_owned, uintptr(t.original))
		}
	}
	lp_resume(handles)
	lp_free_marked(freeable)

	refreshed := 0
	for r, i in refresh_targets {
		if refresh_ok[i] {
			refreshed += 1
		} else {
			fmt.eprintfln("[livepatch] could not make @(rodata)/#load copy writable to refresh it (%d bytes @ %p)", r.size, r.exe)
		}
	}
	if refreshed > 0 {
		fmt.printfln("[livepatch] refreshed %d @(rodata)/#load global(s)", refreshed)
	}
	if swap_type_table {
		if did_swap {
			fmt.println("[livepatch] refreshed reflection type_table (edited/new types now visible)")
		} else {
			fmt.eprintln("[livepatch] could not make runtime.type_table writable to refresh reflection")
		}
	}
	for t, i in targets {
		if patch_ok[i] {
			fmt.printfln("[livepatch] patched %s: %p -> %p (%s)", t.name, t.original, t.fresh, patch_atomic[i] ? "atomic" : "overwrite")
		}
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
	lp_phase("patch", &mark)

	if patched != len(targets) {
		return false
	}

	for k, v in obj_hashes {
		_lp_cur[k] = v
	}

	if did_swap {
		lp_advance_live_types(fresh_ti_hdr)
		if have_obj_type_hash {
			_lp_cur_type_hash = obj_type_hash
			_lp_cur_type_hash_ready = true
		}
	}

	lp_call_patch_hooks(post_tbl, changed, lp_resolve_post_hook, &all_defs)

	{
		gen: Lp_Generation
		gen.serial = gen_serial
		gen.owned  = gen_owned
		gen.blocks = make([dynamic]rawptr, runtime.heap_allocator())
		gen.pdata  = make([dynamic]win.PRUNTIME_FUNCTION, runtime.heap_allocator())
		gen.ranges = make([dynamic]Lp_Range, runtime.heap_allocator())
		for &o in objs {
			if o.block != nil {
				append(&gen.blocks, o.block)
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
	return true
}
