#+build windows
package livepatch_migrate_full

// Comprehensive self-driving test: migrate live state across a reload that changes the
// struct layout in EVERY simple way at once — add a field, rename a field (by `fs`
// alias), reorder fields, remove a field, AND re-order an enum's constants. All fields
// that survive by name keep their values at their new offsets; the enum value is
// remapped by name; the new field zeroes; the removed field is dropped.
//
// v1/state.odin and v2/state.odin hold the two layouts; app.odin is layout-agnostic
// (state lives behind a rawptr). Exit 0 = PASS. See run_migrate_full_test.ps1.

import "base:runtime"
import "core:fmt"
import "core:os"
import lp "core:livepatch"

// Filled by the (v2) `report` hot proc after migration; asserted by `main`.
Report :: struct {
	hp:              i64, // renamed from `health`
	mana:            i64, // newly added
	color:           i64, // enum, remapped by name
	s0:              i64, // scores[0], survives a reorder
	s2:              i64, // scores[2]
	shape_is_square: i64, // union: active variant preserved by name across a variant reorder
	shape_val:       i64, // union: payload preserved
}

g_state:    rawptr
g_blob:     []byte
g_report:   Report
g_migrated: bool

@(pre_patch_hook)
save :: proc(changed: []lp.Type_Change) {
	if g_state == nil { return }
	g_blob = serialize((^State)(g_state), context.allocator)
}

@(post_patch_hook)
load :: proc(changed: []lp.Type_Change) {
	new_ti: ^runtime.Type_Info
	for c in changed {
		if named, ok := c.new.variant.(runtime.Type_Info_Named); ok && named.name == "State" {
			new_ti = c.new
		}
	}
	if new_ti == nil { return }

	new_ptr := rawptr(new(State))
	deserialize(new_ptr, new_ti, g_blob)
	free(g_state)
	delete(g_blob)
	g_state = new_ptr
	g_blob = nil

	g_report = report(g_state) // v2 report reads the new layout
	g_migrated = true
}

OBJ_PATH :: "migrate_full_hot.obj"

fail :: proc(reason: string) -> ! {
	fmt.printfln("MIGRATE-FULL: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	g_state = rawptr(new(State))
	init_state(g_state) // v1: health=99, color=.Green, scores={5,6,7}, dead=true

	if !lp.apply(OBJ_PATH) {
		fail("reload did not fully apply (is migrate_full_hot.obj present, same manifest?)")
	}
	if !g_migrated { fail("post hook did not migrate State") }

	// health -> hp (rename via `fs` alias); value preserved.
	if g_report.hp != 99 { fail(fmt.tprintf("rename failed: hp=%d, expected 99", g_report.hp)) }
	// mana added; zero.
	if g_report.mana != 0 { fail(fmt.tprintf("new field mana not zero: %d", g_report.mana)) }
	// scores reordered ahead of color; values preserved.
	if g_report.s0 != 5 { fail(fmt.tprintf("reorder failed: scores[0]=%d, expected 5", g_report.s0)) }
	if g_report.s2 != 7 { fail(fmt.tprintf("reorder failed: scores[2]=%d, expected 7", g_report.s2)) }
	// enum remap by NAME: v1 .Green(=1) must become v2 .Green(=2), NOT a raw-copied 1.
	if g_report.color != 2 { fail(fmt.tprintf("enum remap failed: color=%d, expected 2 (v2 .Green)", g_report.color)) }
	// union: the active variant (Square) and its payload survive a variant reorder by name.
	if g_report.shape_is_square != 1 { fail("union migration failed: active variant is not Square") }
	if g_report.shape_val != 7 { fail(fmt.tprintf("union payload not preserved: %d, expected 7", g_report.shape_val)) }

	fmt.printfln("MIGRATE-FULL: PASS (hp=%d mana=%d color=%d s0=%d s2=%d shape=Square(%d))",
		g_report.hp, g_report.mana, g_report.color, g_report.s0, g_report.s2, g_report.shape_val)
	os.exit(0)
}
