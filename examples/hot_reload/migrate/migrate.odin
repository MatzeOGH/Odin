#+build windows
package hot_reload_migrate

// Automated demo/test: react to a STRUCT LAYOUT CHANGE across a hot reload, using
// Odin reflection to migrate live state BY FIELD NAME (Windows / x64). Drives itself;
// exits 0 = PASS.
//
// The host keeps its state behind a `rawptr` and never touches the fields directly —
// only @(hot_reload) procs do — so the host binary is layout-agnostic. On reload:
//   * a @(pre_patch_hook) (old code) serializes the live State by name, and
//   * a @(post_patch_hook) (new code) allocates the NEW layout and deserializes the
//     saved fields into it, reflecting via hot_reload.Type_Change.new (the reloaded
//     layout — `type_info_of` in hot code would still give the old one).
//
// The reload edit (run_migrate_test.ps1) inserts a new field `extra` at the FRONT of
// State, which SHIFTS every following field's offset. Name-keyed migration must still
// land `n`, `tag` and `vals` correctly (proving it uses the new offsets, not the old),
// and `extra` must come out zero.

import "base:runtime"
import "core:fmt"
import "core:os"
import hr "core:sys/hot_reload"

// Bumped 1 -> 2 by the reload edit; also gates the code that reads the new `extra`
// field so the v1 (exe) build — which has no such field — still compiles.
EDIT_VERSION :: 1

Kind :: enum u8 { A, B, C }

State :: struct {
	// HR_EXTRA_FIELD  (the reload edit replaces this line with `extra: i64,`)
	n:    i64,
	tag:  Kind,
	vals: [3]i64,
}

// The state, owned by the host as an opaque pointer (layout lives only in hot code).
g_state: rawptr
g_blob:  []byte

// Migration results recorded by the post-patch hook (v2 code) into exe globals, so the
// v1 host can assert them after the reload.
g_migrated_n:    i64
g_migrated_tag:  i64
g_migrated_v0:   i64
g_migrated_v2:   i64
g_migrated_extra: i64
g_migrated:      bool

@(hot_reload)
init_state :: proc(p: rawptr) {
	s := (^State)(p)
	s.n = 42
	s.tag = .B
	s.vals = {10, 20, 30}
}

// @(pre_patch_hook): OLD code, live state still laid out the old way. Serialize it by
// name into a heap blob the post hook will consume.
@(pre_patch_hook)
save :: proc(changed: []hr.Type_Change) {
	if g_state == nil { return }
	g_blob = serialize((^State)(g_state), context.allocator)
	fmt.printfln("[migrate] pre: serialized %d bytes", len(g_blob))
}

// @(post_patch_hook): NEW code. If State's layout changed, build a fresh new-layout
// State and deserialize the saved fields into it by name, then swap the host pointer.
@(post_patch_hook)
load :: proc(changed: []hr.Type_Change) {
	new_ti: ^runtime.Type_Info
	for c in changed {
		if named, ok := c.new.variant.(runtime.Type_Info_Named); ok && named.name == "State" {
			new_ti = c.new
		}
	}
	if new_ti == nil {
		fmt.println("[migrate] post: State layout unchanged; keeping state as-is")
		return
	}

	// size_of(State) here is the NEW size (this is new code). Zero it so removed/new
	// fields are well-defined, then deserialize the saved fields into their new offsets.
	new_ptr := rawptr(new(State))
	deserialize(new_ptr, new_ti, g_blob)

	free(g_state)
	delete(g_blob)
	g_state = new_ptr
	g_blob = nil

	s := (^State)(g_state)
	g_migrated_n   = s.n
	g_migrated_tag = i64(s.tag)
	g_migrated_v0  = s.vals[0]
	g_migrated_v2  = s.vals[2]
	when EDIT_VERSION >= 2 {
		g_migrated_extra = s.extra
	}
	g_migrated = true
	fmt.printfln("[migrate] post: migrated State (new size %d): n=%d tag=%d vals[0]=%d vals[2]=%d",
		new_ti.size, s.n, g_migrated_tag, s.vals[0], s.vals[2])
}

OBJ_PATH :: "migrate_hot.obj"

fail :: proc(reason: string) -> ! {
	fmt.printfln("MIGRATE-TEST: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	fmt.printfln("migrate-test — EDIT_VERSION=%d", EDIT_VERSION)

	g_state = rawptr(new(State))
	init_state(g_state)   // n=42, tag=.B(=1), vals={10,20,30}

	if !hr.apply(OBJ_PATH) {
		fail("reload did not fully apply (is migrate_hot.obj present, same manifest?)")
	}

	if !g_migrated { fail("post-patch hook did not migrate State (was its layout change detected?)") }

	// Surviving fields must keep their values at their NEW offsets; the added field is zero.
	if g_migrated_n    != 42 { fail(fmt.tprintf("n not preserved: got %d, expected 42", g_migrated_n)) }
	if g_migrated_tag  != 1  { fail(fmt.tprintf("tag not preserved: got %d, expected 1 (.B)", g_migrated_tag)) }
	if g_migrated_v0   != 10 { fail(fmt.tprintf("vals[0] not preserved: got %d, expected 10", g_migrated_v0)) }
	if g_migrated_v2   != 30 { fail(fmt.tprintf("vals[2] not preserved: got %d, expected 30", g_migrated_v2)) }
	if g_migrated_extra != 0 { fail(fmt.tprintf("new field `extra` not zero: got %d", g_migrated_extra)) }

	fmt.printfln("MIGRATE-TEST: PASS (n=%d tag=%d vals[0]=%d vals[2]=%d extra=%d)",
		g_migrated_n, g_migrated_tag, g_migrated_v0, g_migrated_v2, g_migrated_extra)
	os.exit(0)
}
