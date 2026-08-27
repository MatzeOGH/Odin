#+build windows
package hot_reload_migrate_twice

// Multi-reload regression test (Windows / x64) for the loader's TYPE baseline. Drives
// itself; exit 0 = PASS. See run_migrate_twice_test.ps1.
//
// The exe is built at v1; two reload objects at v2 and v3 (see v1/v2/v3/state.odin). main()
// applies v2 then v3 and asserts, from the SECOND reload's `changed` diff, that the loader
// advances its type baseline every reload instead of freezing it at process start:
//
//   1. State's `Type_Change.old.size` on reload 2 equals the v2 (LAST reload) size, NOT the
//      v1 app-start size. This is the exact bug: with a frozen baseline `old` is forever the
//      app-start layout, so a hook that reflects via `old` corrupts state after reload #1.
//   2. OnlyV2 changed only at v2 and is untouched v2->v3, so it must NOT be re-flagged on
//      reload 2 (a frozen baseline diffs it vs v1 and wrongly re-migrates it every reload).
//   3. NewV2 was introduced at v2 and changes at v3, so it MUST be flagged on reload 2 (a
//      frozen baseline treats a type added in a prior reload as brand-new forever and never
//      migrates it again).
//
// It also confirms State's surviving fields keep their values through BOTH reloads and that
// the deferred-free generation count stays bounded (no per-reload leak).

import "base:runtime"
import "core:fmt"
import "core:os"
import hr "core:hot_reload"

// State / Kind / OnlyV2 / NewV2 / VER are defined per version in state.odin.

g_state: rawptr
g_blob:  []byte

// Which reload is in progress (main sets it before each apply); the hooks read it to know
// whether they are observing reload 1 (v1->v2) or reload 2 (v2->v3).
g_pass: int

// Observations recorded into exe globals (resolved to the exe's copy across the reload).
v1_state_size:     int
v2_state_new_size: int
v3_state_old_size: int
v3_onlyv2_flagged: bool
v3_newv2_flagged:  bool
pre_fired:         int
post_fired:        int
mig_n:             i64

// Keep OnlyV2 (all versions) and NewV2 (v2+) referenced so they land in the type table the
// loader diffs. Modeled on hook_test's `touch`.
touch :: proc() {
	o: OnlyV2
	_ = o
	when VER >= 2 {
		n: NewV2
		_ = n
	}
}

init_state :: proc(p: rawptr) {
	s := (^State)(p)
	s.n = 42
	s.tag = .B
	s.vals = {10, 20, 30}
}

// @(pre_patch_hook): OLD/live code. Serialize the live State by name (reflection here reads
// the currently-live layout via the swapped type_table).
@(pre_patch_hook)
on_pre :: proc(changed: []hr.Type_Change) {
	pre_fired += 1
	if g_state != nil {
		g_blob = serialize((^State)(g_state), context.allocator)
	}
}

// @(post_patch_hook): NEW code. Record what the diff reported this reload, then migrate State
// into the new layout via `change.new` (NOT type_info_of, which still gives the old table).
@(post_patch_hook)
on_post :: proc(changed: []hr.Type_Change) {
	post_fired += 1
	state_new: ^runtime.Type_Info
	for c in changed {
		named, ok := c.new.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		switch named.name {
		case "State":
			state_new = c.new
			if g_pass == 1 { v2_state_new_size = c.new.size }
			if g_pass == 2 { v3_state_old_size = c.old.size } // old MUST be the v2 (live) layout
		case "OnlyV2":
			if g_pass == 2 { v3_onlyv2_flagged = true }
		case "NewV2":
			if g_pass == 2 { v3_newv2_flagged = true }
		}
	}
	if state_new != nil && g_blob != nil {
		new_ptr := rawptr(new(State))
		deserialize(new_ptr, state_new, g_blob)
		if g_state != nil { free(g_state) }
		delete(g_blob)
		g_state = new_ptr
		g_blob = nil
		mig_n = (^State)(g_state).n
	}
}

fail :: proc(reason: string) -> ! {
	fmt.printfln("MIGRATE-TWICE: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	fmt.printfln("migrate-twice — VER=%d", VER)
	touch()
	v1_state_size = size_of(State) // exe is v1
	g_state = rawptr(new(State))
	init_state(g_state) // n=42, tag=.B, vals={10,20,30}

	fmt.println("== reload 1 (v1 -> v2) ==")
	g_pass = 1
	if !hr.apply("mt1_hot.obj") { fail("reload 1 did not apply (is mt1_hot.obj present, same manifest?)") }

	fmt.println("== reload 2 (v2 -> v3) ==")
	g_pass = 2
	if !hr.apply("mt2_hot.obj") { fail("reload 2 did not apply (is mt2_hot.obj present, same manifest?)") }

	// Both hooks must have fired once per reload.
	if pre_fired  != 2 { fail(fmt.tprintf("pre hook fired %d times, expected 2",  pre_fired)) }
	if post_fired != 2 { fail(fmt.tprintf("post hook fired %d times, expected 2", post_fired)) }

	// (1) The core assertion: on reload 2, State's `old` is the LAST-reloaded (v2) layout, not
	//     the app-start (v1) one.
	if v2_state_new_size == 0 { fail("v2 State size was not recorded on reload 1") }
	if v3_state_old_size == 0 { fail("State was not flagged on reload 2 (old size never recorded)") }
	if v3_state_old_size == v1_state_size {
		fail(fmt.tprintf("Type_Change.old is STALE (app-start): old.size=%d == v1 size=%d — the type baseline never advanced",
			v3_state_old_size, v1_state_size))
	}
	if v3_state_old_size != v2_state_new_size {
		fail(fmt.tprintf("Type_Change.old.size=%d does not match the last reload (v2) size=%d",
			v3_state_old_size, v2_state_new_size))
	}

	// (2) A type changed only on reload 1 and untouched since must not be re-flagged.
	if v3_onlyv2_flagged {
		fail("OnlyV2 was re-flagged on reload 2 though unchanged since reload 1 (diffed vs app-start, not current-live)")
	}

	// (3) A type introduced on reload 1 must still be migratable when it changes on reload 2.
	if !v3_newv2_flagged {
		fail("NewV2 (added on reload 1) was NOT flagged when it changed on reload 2 (frozen baseline treats it brand-new forever)")
	}

	// State's surviving field kept its value through BOTH reloads.
	if mig_n != 42 { fail(fmt.tprintf("State.n not preserved across two reloads: got %d, expected 42", mig_n)) }

	// The deferred-free machinery must keep the mapped-block generation count bounded.
	if hr.live_generations() > 3 {
		fail(fmt.tprintf("reload generations not reclaimed: %d live (expected <= 3)", hr.live_generations()))
	}

	fmt.printfln("MIGRATE-TWICE: PASS (v1=%d v2=%d v3.old=%d onlyv2_reflagged=%v newv2_flagged=%v n=%d gens=%d)",
		v1_state_size, v2_state_new_size, v3_state_old_size, v3_onlyv2_flagged, v3_newv2_flagged, mig_n, hr.live_generations())
	os.exit(0)
}
