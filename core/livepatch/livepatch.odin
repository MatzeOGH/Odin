#+build windows
package livepatch

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import win "core:sys/windows"

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
IMAGE_SCN_MEM_EXECUTE       :: 0x20000000
IMAGE_SCN_MEM_WRITE         :: 0x80000000
IMAGE_SCN_LNK_NRELOC_OVFL   :: 0x01000000

LP_CONST_SECTION :: ".odinti"

IMAGE_REL_AMD64_ADDR64   :: 0x01
IMAGE_REL_AMD64_ADDR32NB :: 0x03
IMAGE_REL_AMD64_REL32    :: 0x04
IMAGE_REL_AMD64_SECREL :: 0x0B

COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

New_Global_Init :: struct {
	arena_offset: i64,
	flag_offset:  i64,
	size:         i64,
	blob:         rawptr,
}

Type_Change :: struct {
	old: ^runtime.Type_Info,
	new: ^runtime.Type_Info,
}

Patch_Hook :: #type proc(changed: []Type_Change)

Patch_Hook_Entry :: struct {
	name:     [^]u8,
	name_len: i64,
}

Patch_Hook_Table :: struct {
	count:   i64,
	entries: [0]Patch_Hook_Entry,
}

@(private)
lp_hook_count :: proc(tbl_addr: rawptr) -> int {
	if tbl_addr == nil {
		return 0
	}
	return int((^Patch_Hook_Table)(tbl_addr).count)
}

@(private)
lp_call_patch_hooks :: proc(tbl_addr: rawptr, changed: []Type_Change, resolve: proc(name: string, ctx: rawptr) -> rawptr, ctx: rawptr) {
	if tbl_addr == nil {
		return
	}
	tbl := (^Patch_Hook_Table)(tbl_addr)
	entries := ([^]Patch_Hook_Entry)(uintptr(tbl_addr) + size_of(i64))
	for i in 0 ..< int(tbl.count) {
		e := entries[i]
		name := string(e.name[:e.name_len])
		addr := resolve(name, ctx)
		if addr == nil {
			fmt.eprintfln("[livepatch] could not resolve patch hook %q; skipping", name)
			continue
		}
		hook := (Patch_Hook)(addr)
		hook(changed)
	}
}

LP_TYPE_INFOS_SYM :: "__odin_livepatch_type_infos"

LP_TYPE_TABLE_SYM :: "runtime::type_table"

@(private)
lp_layout_differs :: proc(a, b: ^runtime.Type_Info) -> bool {
	ba := runtime.type_info_base(a)
	bb := runtime.type_info_base(b)
	if ba == nil || bb == nil {
		return false
	}
	if ba.size != bb.size {
		return true
	}

	sa, a_struct := ba.variant.(runtime.Type_Info_Struct)
	sb, b_struct := bb.variant.(runtime.Type_Info_Struct)
	if a_struct != b_struct {
		return true
	}
	if a_struct && b_struct {
		if sa.field_count != sb.field_count {
			return true
		}
		for i in 0 ..< int(sa.field_count) {
			if sa.names[i] != sb.names[i] || sa.offsets[i] != sb.offsets[i] {
				return true
			}
			// A field retyped to a same-size type (e.g. i32 -> f32) keeps its offset but
			// changes how the bytes are interpreted; compare the field type identity too,
			// otherwise reflection would keep showing the old field type after a reload.
			fa, fb := sa.types[i], sb.types[i]
			if fa != nil && fb != nil && fa.id != fb.id {
				return true
			}
		}
		return false
	}

	ea, a_enum := ba.variant.(runtime.Type_Info_Enum)
	eb, b_enum := bb.variant.(runtime.Type_Info_Enum)
	if a_enum != b_enum {
		return true
	}
	if a_enum && b_enum {
		if len(ea.names) != len(eb.names) {
			return true
		}
		for i in 0 ..< len(ea.names) {
			if ea.names[i] != eb.names[i] || ea.values[i] != eb.values[i] {
				return true
			}
		}
		return false
	}

	ua, a_union := ba.variant.(runtime.Type_Info_Union)
	ub, b_union := bb.variant.(runtime.Type_Info_Union)
	if a_union != b_union {
		return true
	}
	if a_union && b_union {
		if len(ua.variants) != len(ub.variants) || ua.tag_offset != ub.tag_offset {
			return true
		}
		for i in 0 ..< len(ua.variants) {
			na, _ := ua.variants[i].variant.(runtime.Type_Info_Named)
			nb, _ := ub.variants[i].variant.(runtime.Type_Info_Named)
			if lp_qualified_name(na) != lp_qualified_name(nb) {
				return true
			}
		}
		return false
	}

	return false
}

@(private)
lp_read_type_infos :: proc(tbl_addr: rawptr) -> []^runtime.Type_Info {
	if tbl_addr == nil {
		return nil
	}
	return (^[]^runtime.Type_Info)(tbl_addr)^
}

@(private)
lp_qualified_name :: proc(named: runtime.Type_Info_Named) -> string {
	return fmt.tprintf("%s.%s", named.pkg, named.name)
}

@(private) _lp_live_types: map[string]^runtime.Type_Info
@(private) _lp_live_types_ready: bool

@(private)
lp_fill_live_types :: proc(tis: []^runtime.Type_Info) {
	_lp_live_types = make(map[string]^runtime.Type_Info, runtime.heap_allocator())
	for ti in tis {
		if ti == nil { continue }
		if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
			key := strings.clone(lp_qualified_name(named), runtime.heap_allocator())
			_lp_live_types[key] = ti
		}
	}
}

@(private)
lp_live_types_by_name :: proc() -> map[string]^runtime.Type_Info {
	if _lp_live_types_ready {
		return _lp_live_types
	}
	_lp_live_types_ready = true
	lp_fill_live_types(lp_read_type_infos(lp_resolve_pdb(LP_TYPE_INFOS_SYM)))
	return _lp_live_types
}

@(private)
lp_advance_live_types :: proc(new_hdr: rawptr) {
	new_tis := lp_read_type_infos(new_hdr)
	if len(new_tis) == 0 {
		return
	}
	if _lp_live_types_ready {
		for k in _lp_live_types {
			delete(k, runtime.heap_allocator())
		}
		delete(_lp_live_types)
	}
	lp_fill_live_types(new_tis)
	_lp_live_types_ready = true
}

@(private)
lp_build_type_changes :: proc(data: []byte, sym_off, n_syms, strtab_off: int, section_bases: []rawptr) -> []Type_Change {
	new_addr, _ := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, LP_TYPE_INFOS_SYM)
	new_tis := lp_read_type_infos(new_addr)
	if len(new_tis) == 0 {
		return nil
	}
	old_by_name := lp_live_types_by_name()
	if len(old_by_name) == 0 {
		return nil
	}

	direct := make(map[string]bool, context.temp_allocator)
	for ti in new_tis {
		if ti == nil { continue }
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		q := lp_qualified_name(named)
		if old_ti, found := old_by_name[q]; found && lp_layout_differs(old_ti, ti) {
			direct[q] = true
		}
	}

	memo := make(map[rawptr]bool, context.temp_allocator)
	changes := make([dynamic]Type_Change, context.allocator)
	for ti in new_tis {
		if ti == nil { continue }
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		old_ti, found := old_by_name[lp_qualified_name(named)]
		if !found { continue }
		if lp_contains_changed(ti, direct, &memo) {
			append(&changes, Type_Change{old = old_ti, new = ti})
		}
	}
	return changes[:]
}

@(private)
lp_type_table_needs_swap :: proc(data: []byte, sym_off, n_syms, strtab_off: int, section_bases: []rawptr) -> bool {
	new_addr, _ := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, LP_TYPE_INFOS_SYM)
	new_tis := lp_read_type_infos(new_addr)
	if len(new_tis) == 0 {
		return false
	}
	old_by_name := lp_live_types_by_name()
	for ti in new_tis {
		if ti == nil { continue }
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		old_ti, found := old_by_name[lp_qualified_name(named)]
		if !found {
			return true
		}
		if lp_layout_differs(old_ti, ti) {
			return true
		}
	}
	return false
}

// lp_contains_changed reports whether `ti` is, or transitively embeds BY VALUE, a directly
// changed type. It deliberately recurses only through value-embedding aggregates (struct fields,
// (enumerated) array elements, union variants) — the same set as the compiler-side
// lb_livepatch_layout_hash and lp_layout_differs. It intentionally does NOT follow pointers,
// slices, maps or dynamic arrays: their header layout is unaffected by the pointee/element type
// changing, and stopping there also keeps the recursion finite.
@(private)
lp_contains_changed :: proc(ti: ^runtime.Type_Info, direct: map[string]bool, memo: ^map[rawptr]bool) -> bool {
	if ti == nil {
		return false
	}
	if v, ok := memo[ti]; ok {
		return v
	}
	memo[ti] = false

	result := false
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
		if direct[lp_qualified_name(named)] {
			result = true
		}
	}

	base := runtime.type_info_base(ti)
	#partial switch b in base.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(b.field_count) {
			if lp_contains_changed(b.types[i], direct, memo) { result = true }
		}
	case runtime.Type_Info_Array:
		if lp_contains_changed(b.elem, direct, memo) { result = true }
	case runtime.Type_Info_Enumerated_Array:
		if lp_contains_changed(b.elem, direct, memo) { result = true }
	case runtime.Type_Info_Union:
		for variant in b.variants {
			if lp_contains_changed(variant, direct, memo) { result = true }
		}
	}

	memo[ti] = result
	return result
}

@(private)
lp_resolve_pre_hook :: proc(name: string, ctx: rawptr) -> rawptr {
	return lp_resolve_pdb(name)
}

@(private)
lp_resolve_post_hook :: proc(name: string, ctx: rawptr) -> rawptr {
	defs := (^map[string]rawptr)(ctx)
	if addr, ok := defs^[name]; ok {
		return addr
	}
	return nil
}

Func_Hash :: struct {
	name_hash:    u64,
	content_hash: u64,
}

@(private)
lp_fnv64 :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(s) {
		h = (h ~ u64(s[i])) * 0x100000001b3
	}
	return h
}

@(private)
_lp_cur: map[u64]u64
@(private)
_lp_cur_ready: bool

@(private)
lp_read_func_hashes :: proc(addr: rawptr, dst: ^map[u64]u64) {
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

@(private)
lp_proc_changed :: proc(name: string, obj_hashes: map[u64]u64, have_obj_hashes: bool) -> bool {
	if !have_obj_hashes {
		return true
	}
	nh := lp_fnv64(name)
	obj_ch, has_obj := obj_hashes[nh]
	cur, has_cur := _lp_cur[nh]
	if has_obj && has_cur {
		return obj_ch != cur
	}
	return true
}

@(private) _lp_busy: b32

Lp_Range :: struct {
	lo, hi: uintptr,
}
Lp_Generation :: struct {
	serial: int,
	blocks: [dynamic]rawptr,
	pdata:  [dynamic]win.PRUNTIME_FUNCTION,
	ranges: [dynamic]Lp_Range,
	owned:  [dynamic]uintptr,
}
@(private) _lp_generations: [dynamic]Lp_Generation
@(private) _lp_serial: int

live_generations :: proc() -> int {
	when !ODIN_LIVEPATCH { return 0 }
	return len(_lp_generations)
}
@(private) _lp_owner: map[uintptr]int

@(private)
lp_thread_touches :: proc(h: win.HANDLE, ranges: [dynamic]Lp_Range) -> bool {
	ctx: win.CONTEXT
	ctx.ContextFlags = win.CONTEXT_FULL
	if !win.GetThreadContext(h, &ctx) {
		return true
	}
	MAX_FRAMES :: 256
	for _ in 0 ..< MAX_FRAMES {
		pc := uintptr(ctx.Rip)
		if pc == 0 {
			return false
		}
		for r in ranges {
			if pc >= r.lo && pc < r.hi {
				return true
			}
		}
		image_base: win.DWORD64
		fe := win.RtlLookupFunctionEntry(win.DWORD64(pc), &image_base, nil)
		if fe == nil {
			sp := uintptr(ctx.Rsp)
			if sp == 0 {
				return true
			}
			ctx.Rip = win.DWORD64((^uintptr)(sp)^)
			ctx.Rsp = win.DWORD64(sp + 8)
		} else {
			handler_data: rawptr
			establisher:  win.DWORD64
			win.RtlVirtualUnwind(0, image_base, win.DWORD64(pc), fe, &ctx, &handler_data, &establisher, nil)
		}
	}
	return true
}

@(private)
lp_try_free_old_generations :: proc(handles: [dynamic]win.HANDLE) {
	if len(_lp_generations) == 0 {
		return
	}
	kept := make([dynamic]Lp_Generation, 0, len(_lp_generations), runtime.heap_allocator())
	freed := 0
	for gen in _lp_generations {
		referenced := false
		for e in gen.owned {
			if _lp_owner[e] == gen.serial {
				referenced = true
				break
			}
		}
		if referenced {
			append(&kept, gen)
			continue
		}
		in_use := false
		for h in handles {
			if lp_thread_touches(h, gen.ranges) {
				in_use = true
				break
			}
		}
		if in_use {
			append(&kept, gen)
			continue
		}
		for p in gen.pdata {
			win.RtlDeleteFunctionTable(p)
		}
		for b in gen.blocks {
			win.VirtualFree(b, 0, win.MEM_RELEASE)
		}
		delete(gen.blocks)
		delete(gen.pdata)
		delete(gen.ranges)
		delete(gen.owned)
		freed += 1
	}
	delete(_lp_generations)
	_lp_generations = kept
	if freed > 0 {
		fmt.printfln("[livepatch] freed %d stale reload generation(s); %d still in use", freed, len(kept))
	}
}

apply :: proc(obj_path: string) -> bool {
	when !ODIN_LIVEPATCH { return false }
	return apply_many({obj_path})
}

apply_dir :: proc(dir := "hot_objs") -> bool {
	when !ODIN_LIVEPATCH { return false }
	pattern := fmt.tprintf("%s/*.obj", dir)
	matches, err := filepath.glob(pattern, context.temp_allocator)
	if err != nil || len(matches) == 0 {
		fmt.eprintfln("[livepatch] apply_dir: no .obj files found in %q", dir)
		return false
	}
	return apply_many(matches)
}

build_patch :: proc(odin := "odin", manifest := "odin-livepatch.manifest", env: []string = nil) -> bool {
	when !ODIN_LIVEPATCH { return false }
	pkg_dir, ok := lp_manifest_pkg_dir(manifest)
	if !ok {
		fmt.eprintfln("[livepatch] build_patch: no pkg_dir in manifest %q (build the exe with -livepatch first)", manifest)
		return false
	}
	return lp_run_patch_build(odin, pkg_dir, env)
}

apply_patch :: proc(odin := "odin", manifest := "odin-livepatch.manifest", env: []string = nil) -> bool {
	when !ODIN_LIVEPATCH { return false }
	pkg_dir, ok := lp_manifest_pkg_dir(manifest)
	if !ok {
		fmt.eprintfln("[livepatch] apply_patch: no pkg_dir in manifest %q (build the exe with -livepatch first)", manifest)
		return false
	}
	if !lp_run_patch_build(odin, pkg_dir, env) {
		return false
	}
	objs_dir, _ := filepath.join({pkg_dir, "hot_objs"}, context.temp_allocator)
	return apply_dir(objs_dir)
}

@(private)
lp_run_patch_build :: proc(odin: string, pkg_dir: string, env: []string) -> bool {
	cmd := []string{odin, "build", pkg_dir, "-livepatch-patch"}
	fmt.printfln("[livepatch] rebuilding patch: %s build %q -livepatch-patch", odin, pkg_dir)
	state, sout, serr, err := os.process_exec({command = cmd, env = env}, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("[livepatch] build failed to launch %q (is it on PATH?): %v", odin, err)
		return false
	}
	if len(sout) > 0 { fmt.print(string(sout)) }
	if len(serr) > 0 { fmt.eprint(string(serr)) }
	if state.exit_code != 0 {
		fmt.eprintfln("[livepatch] patch build failed (exit %d) — not reloading, running code left as-is", state.exit_code)
		return false
	}
	return true
}

@(private)
lp_manifest_pkg_dir :: proc(manifest_path: string) -> (string, bool) {
	data, err := os.read_entire_file(manifest_path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "pkg_dir ") {
			pd := strings.trim_space(l[len("pkg_dir "):])
			if len(pd) > 0 {
				return pd, true
			}
		}
	}
	return "", false
}

apply_many :: proc(obj_paths: []string) -> bool {
	when !ODIN_LIVEPATCH { return false }
	if _, swapped := intrinsics.atomic_compare_exchange_strong(&_lp_busy, false, true); !swapped {
		fmt.eprintln("[livepatch] a reload is already in progress; apply()/apply_many() must be called from one thread, one reload at a time")
		return false
	}
	defer intrinsics.atomic_store(&_lp_busy, false)

	start := time.tick_now()
	defer fmt.printfln("[livepatch] apply_many took %v", time.tick_since(start))

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

	section_header :: proc(data: []byte, sec_off, i: int) -> ^Coff_Section_Header {
		return (^Coff_Section_Header)(raw_data(data[sec_off + i*SECTION_HDR_SIZE:]))
	}

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
	PAGE :: 0x1000

	objs := make([dynamic]Obj, 0, len(obj_paths), context.temp_allocator)

	// Until we start modifying the running image (refresh/type-table swap/patch), the obj
	// blocks + their registered unwind tables are owned by nobody, so any early `return false`
	// (bad read, alloc failure, build-id mismatch, unresolved symbol, ...) would leak them and
	// leave stale RtlAddFunctionTable registrations — very common in an edit loop. This defer
	// reclaims them on every such path. Once patching begins we set `committed = true`: from
	// that point the running exe may reference the blocks (patched jumps, swapped type_table),
	// so they must NOT be freed here — they are handed to a reload generation instead.
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
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintln("[livepatch] could not read object:", path, err)
			return false
		}
		if len(data) < FILE_HDR_SIZE {
			fmt.eprintln("[livepatch] object too small:", path)
			return false
		}
		hdr := (^Coff_File_Header)(raw_data(data))
		if int(hdr.machine) != IMAGE_FILE_MACHINE_AMD64 {
			fmt.eprintfln("[livepatch] %s: unexpected machine 0x%x (need AMD64)", path, int(hdr.machine))
			return false
		}

		o: Obj
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
			total = ((total + PAGE - 1) / PAGE) * PAGE
			o.offsets[i + 1] = total
			total += size
		}
		total = ((total + PAGE - 1) / PAGE) * PAGE
		o.total = total

		o.block = alloc_near_exe(total)
		if o.block == nil {
			fmt.eprintln("[livepatch] could not reserve memory within 2GB of the exe for", path)
			return false
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
		append(&objs, o)
	}

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

	all_syms := make(map[string]rawptr, context.temp_allocator)
	all_defs := make(map[string]rawptr, context.temp_allocator)
	Hot :: struct { name: string, obj: int }
	hot_names := make([dynamic]Hot, context.temp_allocator)
	hot_detect_misses := 0 // changed, existing, livepatchable procs whose prologue failed pad detection
	for &o, oi in objs {
		i := 0
		for i < o.n_syms {
			sym := coff_symbol(o.data, o.sym_off, i)
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
								// A known-livepatchable (present in the func-hash table), existing,
								// changed proc that fails pad detection means the structural pad
								// heuristic likely broke — surface it rather than silently skipping.
								if !hot && changed && have_obj_hashes && lp_fnv64(name) in obj_hashes {
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
			i += 1 + int(sym.number_of_aux_symbols)
		}
	}

	if hot_detect_misses > 0 {
		fmt.eprintfln("[livepatch] WARNING: %d changed livepatchable procedure(s) exist in the running exe but their prologue did not match a patch pad; hot-proc detection may be broken (did the compiler's patchable-function-prefix NOP encoding change?). These procedures were NOT patched.", hot_detect_misses)
	}

	unresolved, unsupported := 0, 0
	unresolved_text := 0
	tls_cache := make(map[string]uintptr, context.temp_allocator)
	for &o in objs {
		{
			i := 0
			for i < o.n_syms {
				sym := coff_symbol(o.data, o.sym_off, i)
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
				i += 1 + int(sym.number_of_aux_symbols)
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
					if off, ok := lp_tls_offset(sname, &tls_cache); ok {
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
	}
	if unresolved > 0 || unsupported > 0 {
		fmt.eprintfln("[livepatch] note: %d unresolved and %d unsupported relocations (fine if only in code you don't call)", unresolved, unsupported)
	}
	if unresolved_text > 0 {
		fmt.eprintfln("[livepatch] aborting reload: %d unresolved relocation(s) in executable code (see names above)", unresolved_text)
		return false
	}

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
	}

	pre_tbl := lp_resolve_pdb("__odin_livepatch_pre_patch_hooks")
	post_tbl: rawptr
	changed: []Type_Change
	if meta_i >= 0 {
		mo := &objs[meta_i]
		post_tbl, _ = find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_livepatch_post_patch_hooks")
		if lp_hook_count(pre_tbl) > 0 || lp_hook_count(post_tbl) > 0 {
			changed = lp_build_type_changes(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases)
		}
	}
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
			p += 8
			for _ in 0 ..< int(count) {
				size := int((^i64)(p)^); p += 8
				nlen := int((^i64)(p)^); p += 8
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
	tt_ref:       rawptr
	fresh_ti_hdr: rawptr
	if meta_i >= 0 {
		mo := &objs[meta_i]
		if lp_type_table_needs_swap(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases) {
			hdr, ok := find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, LP_TYPE_INFOS_SYM)
			if ref := lp_resolve_pdb("__odin_livepatch_type_table_ref"); ref != nil {
				tt_ref = (^rawptr)(ref)^
			} else {
				tt_ref = lp_resolve_pdb(LP_TYPE_TABLE_SYM)
			}
			if ok {
				fresh_ti_hdr = hdr
				swap_type_table = tt_ref != nil
			}
		}
	}

	if len(hot_names) == 0 && len(refresh_targets) == 0 && !swap_type_table {
		lp_call_patch_hooks(post_tbl, changed, lp_resolve_post_hook, &all_defs)
		// Nothing was patched, so the obj blocks + their unwind registrations are reclaimed by
		// the early-return cleanup defer (committed is still false on this no-patch path).
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
			fmt.eprintfln("[livepatch] aborting reload: could not resolve hot procedure %q (original=%v, fresh_found=%v); nothing patched", h.name, original != nil, found)
			return false
		}
		if !lp_has_patch_pad(original) {
			gap := lp_next_symbol_after(uintptr(original)) - uintptr(original)
			if gap < PATCH_LEN {
				fmt.eprintfln("[livepatch] aborting reload: hot procedure %q has no patch pad and only %d bytes to its next symbol (need %d); nothing patched", h.name, gap, PATCH_LEN)
				return false
			}
		}
		append(&targets, Target{h.name, original, fresh})
	}

	regions := make([]Patch_Region, len(targets), context.temp_allocator)
	for t, i in targets {
		lo := uintptr(t.original)
		lo = lo >= PAD_LEN ? lo - PAD_LEN : 0
		regions[i] = Patch_Region{lo, uintptr(t.original) + PATCH_LEN}
	}

	MAX_ATTEMPTS :: 100
	handles: [dynamic]win.HANDLE
	for attempt := 0; ; attempt += 1 {
		handles = lp_suspend_others()
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

	lp_try_free_old_generations(handles)

	_lp_serial += 1
	gen_serial := _lp_serial
	gen_owned := make([dynamic]uintptr, runtime.heap_allocator())

	// From here on the running image may reference the obj blocks (refreshed data is copied,
	// but the type_table swap and patched jumps point INTO them). The blocks are handed to a
	// reload generation below; the early-return cleanup defer must no longer free them.
	committed = true

	for r in refresh_targets {
		old: win.DWORD
		if win.VirtualProtect(r.exe, win.SIZE_T(r.size), win.PAGE_READWRITE, &old) {
			intrinsics.mem_copy(r.exe, r.obj, r.size)
			restored: win.DWORD
			win.VirtualProtect(r.exe, win.SIZE_T(r.size), old, &restored)
			_lp_owner[uintptr(r.exe)] = gen_serial
			append(&gen_owned, uintptr(r.exe))
		} else {
			fmt.eprintfln("[livepatch] could not make @(rodata)/#load copy writable to refresh it (%d bytes @ %p)", r.size, r.exe)
		}
	}
	if len(refresh_targets) > 0 {
		fmt.printfln("[livepatch] refreshed %d @(rodata)/#load global(s)", len(refresh_targets))
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
			fmt.println("[livepatch] refreshed reflection type_table (edited/new types now visible)")
		} else {
			fmt.eprintln("[livepatch] could not make runtime.type_table writable to refresh reflection")
		}
	}

	patched := 0
	for t in targets {
		ok, atomic := patch_jump(t.original, t.fresh)
		if ok {
			fmt.printfln("[livepatch] patched %s: %p -> %p (%s)", t.name, t.original, t.fresh, atomic ? "atomic" : "overwrite")
			patched += 1
			_lp_owner[uintptr(t.original)] = gen_serial
			append(&gen_owned, uintptr(t.original))
		}
	}
	lp_resume(handles)
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
	}

	if patched != len(targets) {
		return false
	}

	for k, v in obj_hashes {
		_lp_cur[k] = v
	}

	if did_swap {
		lp_advance_live_types(fresh_ti_hdr)
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

PATCH_LEN :: 14
PAD_LEN   :: 16

LP_DEBUG_PAD :: #config(LP_DEBUG_PAD, false)

// The compiler-emitted patch pad is a PAD_LEN-byte `patchable-function-prefix`, filled by LLVM's
// NOP emitter. That is NOT guaranteed to be a run of single-byte 0x90s — LLVM emits multi-byte
// NOP encodings (`0F 1F ...`, with `66` operand-size prefixes for longer forms). Decoding the pad
// as a NOP sled (rather than hard-coding 0x90) keeps hot-proc detection working across LLVM
// NOP-encoding changes. lp_nop_len decodes ONE x86-64 NOP at p and returns its byte length (0 if
// not a NOP); lp_is_nop_sled checks that exactly n bytes decode as back-to-back NOPs.
@(private)
lp_nop_len :: proc(p: [^]u8, max: int) -> int {
	i := 0
	for i < max && p[i] == 0x66 { // operand-size prefixes pad out the longer NOP forms
		i += 1
	}
	if i >= max {
		return 0
	}
	if p[i] == 0x90 { // 1-byte NOP (with any leading 0x66 prefixes)
		return i + 1
	}
	if i + 2 < max && p[i] == 0x0F && p[i + 1] == 0x1F { // multi-byte NOP: 0F 1F /0 r/m
		modrm := p[i + 2]
		n := i + 3
		mod := modrm >> 6
		rm  := modrm & 0x7
		if rm == 0x4 { // SIB byte follows
			n += 1
		}
		switch mod {
		case 1: n += 1 // disp8
		case 2: n += 4 // disp32
		case 0:
			if rm == 0x5 { n += 4 } // disp32
		}
		if n <= max {
			return n
		}
	}
	return 0
}

@(private)
lp_is_nop_sled :: proc(pb: [^]u8, n: int) -> bool {
	i := 0
	for i < n {
		l := lp_nop_len(([^]u8)(&pb[i]), n - i)
		if l <= 0 {
			return false
		}
		i += l
	}
	return i == n
}

@(private)
lp_has_patch_pad :: proc(entry: rawptr) -> bool {
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 { // an abs jump we already installed
		return true
	}
	return lp_is_nop_sled(pb, PAD_LEN)
}

@(private)
lp_is_hot_entry :: proc(entry: rawptr) -> bool {
	if uintptr(entry) < PAD_LEN {
		return false
	}
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 {
		return true
	}
	return lp_is_nop_sled(pb, PAD_LEN)
}

@(private)
lp_write_abs_jump :: proc(dst: [^]u8, target: rawptr) {
	dst[0] = 0xFF; dst[1] = 0x25
	dst[2] = 0x00; dst[3] = 0x00; dst[4] = 0x00; dst[5] = 0x00
	(^u64)(&dst[6])^ = u64(uintptr(target))
}

patch_jump :: proc(original: rawptr, target: rawptr) -> (ok: bool, atomic: bool) {
	if lp_patch_atomic(original, target) {
		return true, true
	}
	return lp_patch_overwrite(original, target), false
}

@(private)
lp_patch_atomic :: proc(original: rawptr, target: rawptr) -> bool {
	if uintptr(original) < PAD_LEN {
		return false
	}
	pad := rawptr(uintptr(original) - PAD_LEN)
	pb := ([^]u8)(pad)
	when LP_DEBUG_PAD {
		eb := ([^]u8)(original)
		fmt.eprintfln("[livepatch] pad@%p: % x | entry: %02x %02x", pad,
			pb[0:PAD_LEN], eb[0], eb[1])
	}
	if !lp_has_patch_pad(original) {
		return false
	}

	region_len := win.SIZE_T(PAD_LEN + 2)
	old: win.DWORD
	if !win.VirtualProtect(pad, region_len, win.PAGE_EXECUTE_READWRITE, &old) {
		return false
	}

	lp_write_abs_jump(pb, target)
	win.FlushInstructionCache(win.GetCurrentProcess(), pad, win.SIZE_T(PATCH_LEN))

	intrinsics.atomic_store((^u16)(original), u16(0xEEEB))
	win.FlushInstructionCache(win.GetCurrentProcess(), original, 2)

	restored: win.DWORD
	win.VirtualProtect(pad, region_len, old, &restored)
	return true
}

@(private)
lp_patch_overwrite :: proc(original: rawptr, target: rawptr) -> bool {
	if gap := lp_next_symbol_after(uintptr(original)) - uintptr(original); gap < PATCH_LEN {
		fmt.eprintfln("[livepatch] refusing overwrite patch: only %d bytes to next symbol (need %d)", gap, PATCH_LEN)
		return false
	}
	old_protect: win.DWORD
	if !win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), win.PAGE_EXECUTE_READWRITE, &old_protect) {
		fmt.eprintln("[livepatch] VirtualProtect failed")
		return false
	}
	lp_write_abs_jump(([^]u8)(original), target)
	restored: win.DWORD
	win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), old_protect, &restored)
	win.FlushInstructionCache(win.GetCurrentProcess(), original, win.SIZE_T(PATCH_LEN))
	return true
}

Patch_Region :: struct {
	lo, hi: uintptr,
}

@(private)
lp_suspend_others :: proc() -> [dynamic]win.HANDLE {
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
				if win.SuspendThread(h) != ~win.DWORD(0) {
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
lp_resume :: proc(handles: [dynamic]win.HANDLE) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
}

@(private)
lp_ip_conflicts :: proc(handles: [dynamic]win.HANDLE, regions: []Patch_Region) -> bool {
	for h in handles {
		ctx: win.CONTEXT
		ctx.ContextFlags = win.CONTEXT_CONTROL
		if !win.GetThreadContext(h, &ctx) {
			continue
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

alloc_near_exe :: proc(size: int) -> rawptr {
	return alloc_near(uintptr(win.GetModuleHandleW(nil)), size)
}

alloc_near :: proc(near: uintptr, size: int) -> rawptr {
	sz := win.SIZE_T(size)
	step :: uintptr(0x0010_0000)
	limit :: uintptr(0x6000_0000)
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

foreign {
	@(link_name="_tls_index") _lp_tls_index: u32
}

@(private)
lp_tls_block_base :: proc "contextless" () -> uintptr {
	read_teb_tls :: asm() -> (r: u64) { mov r, [%gs:0x58]; }
	teb_tls := uintptr(read_teb_tls())
	if teb_tls == 0 {
		return 0
	}
	arr := cast([^]uintptr)teb_tls
	return arr[_lp_tls_index]
}

@(private)
lp_resolve :: proc(name: string, na: ^Near_Arena) -> rawptr {
	if p := lp_resolve_external(name); p != nil {
		return p
	}
	IMP :: "__imp_"
	if strings.has_prefix(name, IMP) {
		real := name[len(IMP):]
		if a := lp_resolve_external(real); a != nil {
			return lp_imp_cell(na, uintptr(a))
		}
	}
	return nil
}

@(private)
lp_resolve_external :: proc(name: string) -> rawptr {
	if p := lp_resolve_exported(name); p != nil {
		return p
	}
	switch name {
	case "_tls_index": return &_lp_tls_index
	}
	if p := lp_resolve_pdb(name); p != nil {
		return p
	}
	return nil
}

@(private)
lp_resolve_exported :: proc(name: string) -> rawptr {
	cname, err := strings.clone_to_cstring(name, context.temp_allocator)
	if err != nil {
		return nil
	}
	if h := win.GetModuleHandleW(nil); h != nil {
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

@(private)
_lp_dbghelp_ready: bool

@(private)
_lp_syms: map[string]rawptr

@(private)
Lp_Enum_State :: struct {
	syms: ^map[string]rawptr,
	ctx:  runtime.Context,
}

@(private)
lp_enum_cb :: proc "system" (pSym: win.PSYMBOL_INFOW, size: win.ULONG, user: win.PVOID) -> win.BOOL {
	st := (^Lp_Enum_State)(user)
	context = st.ctx
	NON_ADDR :: win.SYMFLAG_TLSREL | win.SYMFLAG_REGISTER | win.SYMFLAG_REGREL |
	            win.SYMFLAG_FRAMEREL | win.SYMFLAG_VALUEPRESENT | win.SYMFLAG_CONSTANT
	if (u32(pSym.Flags) & NON_ADDR) != 0 {
		return win.TRUE
	}
	n := int(pSym.NameLen)
	if n > 0 {
		wname := ([^]u16)(&pSym.Name[0])
		if name, err := win.utf16_to_utf8(wname[:n], runtime.heap_allocator()); err == nil && len(name) > 0 {
			if _, exists := st.syms[name]; !exists {
				st.syms[name] = rawptr(uintptr(pSym.Address))
			}
		}
	}
	return win.TRUE
}

@(private)
lp_dbghelp_ensure :: proc() -> bool {
	if _lp_dbghelp_ready {
		return len(_lp_syms) > 0
	}
	_lp_dbghelp_ready = true
	if !win.SymInitialize(win.GetCurrentProcess(), nil, true) {
		return false
	}
	win.SymSetOptions(win.SYMOPT_DEFERRED_LOADS)
	_lp_syms = make(map[string]rawptr, runtime.heap_allocator())
	base := win.ULONG64(uintptr(win.GetModuleHandleW(nil)))
	st := Lp_Enum_State{syms = &_lp_syms, ctx = context}
	ok := win.SymEnumSymbolsW(win.GetCurrentProcess(), base, nil, lp_enum_cb, &st)
	if !ok || len(_lp_syms) == 0 {
		fmt.eprintfln("[livepatch] could not enumerate the exe's PDB symbols (SymEnumSymbolsW ok=%v, %d symbols). Build the exe with -livepatch -debug and keep the .pdb next to it.", ok, len(_lp_syms))
		return false
	}
	return true
}

@(private)
lp_resolve_pdb :: proc(name: string) -> rawptr {
	if !lp_dbghelp_ensure() {
		return nil
	}
	return _lp_syms[name]
}

@(private)
lp_next_symbol_after :: proc(addr: uintptr) -> uintptr {
	best := max(uintptr)
	for _, v in _lp_syms {
		a := uintptr(v)
		if a > addr && a < best {
			best = a
		}
	}
	return best
}

@(private)
lp_tls_offset :: proc(varname: string, cache: ^map[string]uintptr) -> (uintptr, bool) {
	if off, ok := cache[varname]; ok {
		return off, true
	}
	base := lp_tls_block_base()
	if base == 0 {
		return 0, false
	}
	acc_name := strings.concatenate({"__odin_lptls$", varname}, context.temp_allocator)
	acc := lp_resolve_pdb(acc_name)
	if acc == nil {
		return 0, false
	}
	addr := (transmute(proc "c" () -> rawptr) acc)()
	off := uintptr(addr) - base
	cache[varname] = off
	return off, true
}

Near_Arena :: struct {
	near:   uintptr,
	block:  rawptr,
	cap:    int,
	used:   int,
	tramps: map[uintptr]rawptr,
	cells:  map[uintptr]rawptr,
}

@(private)
lp_near_bump :: proc(na: ^Near_Arena, n: int) -> rawptr {
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
lp_trampoline_for :: proc(na: ^Near_Arena, target: uintptr) -> rawptr {
	if t, ok := na.tramps[target]; ok {
		return t
	}
	thunk := lp_near_bump(na, 16)
	if thunk == nil {
		return nil
	}
	lp_write_abs_jump(([^]u8)(thunk), rawptr(target))
	na.tramps[target] = thunk
	return thunk
}

@(private)
lp_imp_cell :: proc(na: ^Near_Arena, addr: uintptr) -> rawptr {
	if c, ok := na.cells[addr]; ok {
		return c
	}
	cell := lp_near_bump(na, 8)
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

lp_is_object_local_const :: proc(sh: ^Coff_Section_Header) -> bool {
	return section_name(sh) == LP_CONST_SECTION
}

symbol_name :: proc(sym: ^Coff_Symbol, data: []byte, strtab_off: int) -> string {
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
