#+build windows
package livepatch

import "core:fmt"
import "core:hash"

// Extra data emitted for a new global the reload introduces: where it lives in
// the runtime arena and a once-flag so it is initialized at most once.
New_Global_Init :: struct {
	arena_offset: i64,
	flag_offset:  i64,
	size:         i64,
	blob:         rawptr,
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

Func_Hash :: struct {
	name_hash:    u64,
	content_hash: u64,
}

// Content hashes of the running exe's livepatchable procedures, so a reload can
// tell which procedures actually changed.
@(private)
_lp_cur: map[u64]u64
@(private)
_lp_cur_ready: bool
@(private)
_lp_cur_type_hash: u64
@(private)
_lp_cur_type_hash_ready: bool

// Returns the number of patch hooks in a hook table (0 if the table is nil).
@(private)
lp_hook_count :: proc(tbl_addr: rawptr) -> int {
	if tbl_addr == nil {
		return 0
	}
	return int((^Patch_Hook_Table)(tbl_addr).count)
}

// Resolves and invokes every patch hook in a hook table, passing it the changed types.
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
			fmt.eprintfln("[livepatch] could not resolve patch hook %q. skipping", name)
			continue
		}
		hook := (Patch_Hook)(addr)
		hook(changed)
	}
}

// Hook-address resolver for pre-patch hooks: looks the name up in the exe's PDB.
@(private)
lp_resolve_pre_hook :: proc(name: string, ctx: rawptr) -> rawptr {
	return lp_resolve_pdb(name)
}

// Hook-address resolver for post-patch hooks: looks the name up in the reload's own definitions.
@(private)
lp_resolve_post_hook :: proc(name: string, ctx: rawptr) -> rawptr {
	defs := (^map[string]rawptr)(ctx)
	if addr, ok := defs^[name]; ok {
		return addr
	}
	return nil
}

// Reads a (count, [name_hash, content_hash]...) table into the destination map.
@(private)
lp_read_func_hashes :: proc(addr: rawptr, dst: ^map[u64]u64) {
	if addr == nil {
		return
	}
	count := (^i64)(addr)^
	entries := ([^]Func_Hash)(rawptr(uintptr(addr) + size_of(i64)))
	for k in 0 ..< int(count) {
		e := entries[k]
		dst[e.name_hash] = e.content_hash
	}
}

// Reports whether a procedure's content hash differs between the reload object and the running exe.
@(private)
lp_proc_changed :: proc(name: string, obj_hashes: map[u64]u64, have_obj_hashes: bool) -> bool {
	if !have_obj_hashes {
		return true
	}
	nh := hash.fnv64a(transmute([]byte)name)
	obj_ch, has_obj := obj_hashes[nh]
	cur, has_cur := _lp_cur[nh]
	if has_obj && has_cur {
		return obj_ch != cur
	}
	return true
}
