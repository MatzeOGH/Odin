#+build windows
package livepatch

import "base:intrinsics"
import "base:runtime"

LP_TYPE_INFOS_SYM :: "__odin_livepatch_type_infos"
LP_TYPE_TABLE_SYM :: "runtime::type_table"

Type_Change :: struct {
	old: ^runtime.Type_Info,
	new: ^runtime.Type_Info,
}

@(private)
Qual :: struct {
	pkg, name: string,
}

@(private)
_lp_live_types: map[Qual]^runtime.Type_Info
@(private)
_lp_live_types_ready: bool
@(private)
_lp_latest_ti_hdr: rawptr



// Copies every field present in both structs (matched by name and identical
// type) from `src` into `dst`. Fields only in `dst` keep their current value
// (zero, if freshly allocated); fields only in `src` are dropped. Use it from an
// @(post_patch_hook) to carry a struct's state across a reload that reordered,
// inserted, or removed fields — allocate a new-layout value, migrate_fields into
// it, then repoint. A field whose own type changed layout has a different `id`
// and is skipped rather than copied wrong. Shallow (memcpy per field).
// ponytail: shallow per-field copy; add recursion into nested changed structs if a real case needs it.
migrate_fields :: proc(dst: rawptr, dst_ti: ^runtime.Type_Info, src: rawptr, src_ti: ^runtime.Type_Info) -> (copied: int) {
	if dst == nil || src == nil || dst_ti == nil || src_ti == nil {
		return
	}
	ds, dok := runtime.type_info_base(dst_ti).variant.(runtime.Type_Info_Struct)
	ss, sok := runtime.type_info_base(src_ti).variant.(runtime.Type_Info_Struct)
	if !dok || !sok {
		return
	}
	for di in 0 ..< int(ds.field_count) {
		dtype := ds.types[di]
		for si in 0 ..< int(ss.field_count) {
			if ss.names[si] != ds.names[di] {
				continue
			}
			if stype := ss.types[si]; dtype != nil && stype != nil && dtype.id == stype.id {
				intrinsics.mem_copy(rawptr(uintptr(dst) + ds.offsets[di]), rawptr(uintptr(src) + ss.offsets[si]), dtype.size)
				copied += 1
			}
			break
		}
	}
	return
}

// Reports whether two type infos differ in memory layout (size, struct fields, enum/union members).
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
			if na.pkg != nb.pkg || na.name != nb.name { // compare fields; no need to build strings
				return true
			}
		}
		return false
	}

	return false
}

// Reads the []^Type_Info slice header stored at the given address.
@(private)
lp_read_type_infos :: proc(tbl_addr: rawptr) -> []^runtime.Type_Info {
	if tbl_addr == nil {
		return nil
	}
	return (^[]^runtime.Type_Info)(tbl_addr)^
}

// (Re)builds the live named-type lookup map from a slice of type infos.
@(private)
lp_fill_live_types :: proc(tis: []^runtime.Type_Info) {
	_lp_live_types = make(map[Qual]^runtime.Type_Info, runtime.heap_allocator())
	for ti in tis {
		if ti == nil { continue }
		if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
			_lp_live_types[{named.pkg, named.name}] = ti
		}
	}
}

// Returns the live named-type map, lazily building it from the exe on first use.
@(private)
lp_live_types_by_name :: proc() -> map[Qual]^runtime.Type_Info {
	if _lp_live_types_ready {
		return _lp_live_types
	}
	_lp_live_types_ready = true
	src := _lp_latest_ti_hdr != nil ? _lp_latest_ti_hdr : lp_resolve_pdb(LP_TYPE_INFOS_SYM)
	lp_fill_live_types(lp_read_type_infos(src))
	return _lp_live_types
}

// Invalidates the live named-type map after a type-table swap.
@(private)
lp_advance_live_types :: proc(new_hdr: rawptr) {
	if lp_read_type_infos(new_hdr) == nil {
		return
	}
	_lp_latest_ti_hdr = new_hdr
	if _lp_live_types_ready {
		delete(_lp_live_types)
		_lp_live_types_ready = false
	}
}

// Compares the reload's types against the live ones, reporting whether a type-table swap is needed and (if wanted) which types changed.
@(private)
lp_analyze_types :: proc(data: []byte, sym_off, n_syms, strtab_off: int, section_bases: []rawptr, want_changes: bool) -> (needs_swap: bool, changes: []Type_Change, new_hdr: rawptr) {
	new_hdr, _ = find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, LP_TYPE_INFOS_SYM)
	new_tis := lp_read_type_infos(new_hdr)
	if len(new_tis) == 0 {
		return false, nil, new_hdr
	}
	if !want_changes {
		return true, nil, new_hdr
	}
	old_by_name := lp_live_types_by_name()
	if len(old_by_name) == 0 {
		return false, nil, new_hdr
	}

	direct := make(map[Qual]bool, context.temp_allocator)
	for ti in new_tis {
		if ti == nil { continue }
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		old_ti, found := old_by_name[{named.pkg, named.name}]
		if !found {
			needs_swap = true
			continue
		}
		if lp_layout_differs(old_ti, ti) {
			needs_swap = true
			direct[{named.pkg, named.name}] = true
		}
	}

	memo := make(map[rawptr]bool, context.temp_allocator)
	ch := make([dynamic]Type_Change, context.allocator)
	for ti in new_tis {
		if ti == nil { continue }
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		old_ti, found := old_by_name[{named.pkg, named.name}]
		if !found { continue }
		if lp_contains_changed(ti, direct, &memo) {
			append(&ch, Type_Change{old = old_ti, new = ti})
		}
	}
	return needs_swap, ch[:], new_hdr
}

// Recursively reports whether a type transitively contains any directly-changed type (memoized).
@(private)
lp_contains_changed :: proc(ti: ^runtime.Type_Info, direct: map[Qual]bool, memo: ^map[rawptr]bool) -> bool {
	if ti == nil {
		return false
	}
	if v, ok := memo[ti]; ok {
		return v
	}
	memo[ti] = false

	result := false
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
		if direct[{named.pkg, named.name}] {
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
