#+build windows
package hot_reload_migrate_enum

// Self-driving test for the NESTED, NON-int-enum case (Windows / x64). `State`'s own
// layout does NOT change across the reload — only a `u8`-backed enum it holds gets its
// constants re-ordered. Migrating it correctly needs BOTH:
//   * the diff to flag `State` because a type it embeds by value changed (transitive), and
//   * the serializer to remap the enum at its real (1-byte) size, not assume 8.
// Exit 0 = PASS. See run_migrate_enum_test.ps1.

import "base:runtime"
import "core:fmt"
import "core:os"
import hr "core:hot_reload"

Report :: struct {
	id:     i64,
	facing: i64, // enum value AFTER migration (must be remapped by name, not raw-copied)
	label0: i64,
}

g_state:    rawptr
g_blob:     []byte
g_report:   Report
g_migrated: bool

@(pre_patch_hook)
save :: proc(changed: []hr.Type_Change) {
	if g_state == nil { return }
	g_blob = serialize((^State)(g_state), context.allocator)
}

@(post_patch_hook)
load :: proc(changed: []hr.Type_Change) {
	new_ti: ^runtime.Type_Info
	for c in changed {
		if named, ok := c.new.variant.(runtime.Type_Info_Named); ok && named.name == "State" {
			new_ti = c.new
		}
	}
	if new_ti == nil { return } // State not flagged -> B is broken; g_migrated stays false

	new_ptr := rawptr(new(State))
	deserialize(new_ptr, new_ti, g_blob)
	free(g_state)
	delete(g_blob)
	g_state = new_ptr
	g_blob = nil

	g_report = report(g_state)
	g_migrated = true
}

OBJ_PATH :: "migrate_enum_hot.obj"

fail :: proc(reason: string) -> ! {
	fmt.printfln("MIGRATE-ENUM: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	g_state = rawptr(new(State))
	init_state(g_state) // id=123, facing=.S, label="abcd"

	if !hr.apply(OBJ_PATH) {
		fail("reload did not fully apply (is migrate_enum_hot.obj present, same manifest?)")
	}
	if !g_migrated { fail("post hook did not migrate State — its nested enum change was not flagged (B)") }

	if g_report.id != 123 { fail(fmt.tprintf("id not preserved: %d, expected 123", g_report.id)) }
	// v1 .S == 2 ({N,E,S,W}); v2 .S == 3 ({W,N,E,S}). Remap by name must yield 3, not 2.
	if g_report.facing != 3 { fail(fmt.tprintf("u8 enum not remapped by name: facing=%d, expected 3 (v2 .S)", g_report.facing)) }
	if g_report.label0 != i64('a') { fail(fmt.tprintf("label not preserved: %d, expected %d", g_report.label0, i64('a'))) }

	fmt.printfln("MIGRATE-ENUM: PASS (id=%d facing=%d label0=%c)", g_report.id, g_report.facing, rune(g_report.label0))
	os.exit(0)
}
