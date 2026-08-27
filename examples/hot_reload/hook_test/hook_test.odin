#+build windows
package hot_reload_hook_test

// Automated regression test for the autowired pre/post-patch hooks + type-info diff
// (Windows / x64). Drives itself; exits 0 on success / non-zero on failure (see
// run_hook_test.ps1). It proves:
//   (1) a @(pre_patch_hook) fires before the patch and a @(post_patch_hook) after,
//       with NO registration call — the loader discovers them structurally;
//   (2) the PRE hook runs the RUNNING EXE's (old) code and the POST hook runs the
//       RELOADED OBJECT's (new) code — via a version marker `VER` bumped 1 -> 2;
//   (3) the loader diffs old vs new type-info and hands the hooks exactly the types
//       whose layout changed: the edit adds a field to `State`, so `changed` carries
//       State with old.size 8 and new.size 16;
//   (4) the ordinary hot-reload patch still takes effect.

import "base:runtime"
import "core:fmt"
import "core:os"
import hr "core:sys/hot_reload"

// Bumped 1 -> 2 by the reload edit (run_hook_test.ps1). Exe built with VER==1, reload
// object with VER==2, so PRE (old/exe) sees 1 and POST (new/obj) sees 2.
VER :: 1

// A separate enum whose CONSTANTS are re-ordered by the reload edit (its size does NOT
// change). It must still appear in the diff's `changed` set — this exercises the
// enum-aware layout comparison, not just the struct-size/offset one.
Mode :: enum { Idle, Run, Stop } // edit -> { Stop, Idle, Run }

// `Holder`'s own layout never changes, but it embeds `Mode` by value — so it must be
// flagged transitively (a nested type changed in place). `Shape`'s VARIANTS get
// re-ordered by the edit (same size) — so it must be flagged by the union-aware compare.
Circle :: struct { r: i64 }
Square :: struct { s: i64 }
Holder :: struct { m: Mode }
Shape  :: union { Circle, Square } // edit -> union { Square, Circle }

State :: struct {
	n:    i64,
	mode: Mode,
	// HR_EXTRA_FIELD  (the reload edit inserts `extra: i64,` here -> layout change)
}

// Pull Holder/Shape (and their members) into the type table without embedding them in
// State (which would change State's asserted size).
touch :: proc() -> (Holder, Shape) { return {}, {} }

work :: proc(s: ^State) {
	s.n += 1
	s.mode = .Run
}

// Observations recorded into exe globals (resolved to the exe's copy across the reload).
pre_fired:  int
pre_ver:    int
post_fired: int
post_ver:   int
post_changed_count: int
post_state_old_size: int
post_state_new_size: int
post_saw_state:  bool
post_saw_mode:   bool
post_saw_holder: bool
post_saw_shape:  bool

@(pre_patch_hook)
on_pre :: proc(changed: []hr.Type_Change) {
	pre_fired += 1
	pre_ver = VER
	fmt.printfln("[hook] pre-patch fired: VER=%d changed=%d", VER, len(changed))
}

@(post_patch_hook)
on_post :: proc(changed: []hr.Type_Change) {
	post_fired += 1
	post_ver = VER
	post_changed_count = len(changed)
	for c in changed {
		named, ok := c.new.variant.(runtime.Type_Info_Named)
		if ok {
			fmt.printfln("[hook]   changed: %s  %d -> %d", named.name, c.old.size, c.new.size)
			switch named.name {
			case "State":
				post_saw_state = true
				post_state_old_size = c.old.size
				post_state_new_size = c.new.size
			case "Mode":
				post_saw_mode = true
			case "Holder":
				post_saw_holder = true
			case "Shape":
				post_saw_shape = true
			}
		}
	}
	fmt.printfln("[hook] post-patch fired: VER=%d changed=%d", VER, len(changed))
}

OBJ_PATH :: "hook_hot.obj"

fail :: proc(reason: string) -> ! {
	fmt.printfln("HOOK-TEST: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	fmt.printfln("hook-test — tid %d, VER=%d", os.get_current_thread_id(), VER)
	_, _ = touch() // keep Holder/Shape (and members) in the type table

	if !hr.apply(OBJ_PATH) {
		fail("reload did not fully apply (is hook_hot.obj present, same manifest?)")
	}

	if pre_fired != 1  { fail(fmt.tprintf("pre hook fired %d times, expected 1", pre_fired)) }
	if post_fired != 1 { fail(fmt.tprintf("post hook fired %d times, expected 1", post_fired)) }
	if pre_ver != 1    { fail(fmt.tprintf("pre hook ran wrong code: VER=%d, expected 1 (exe/old)", pre_ver)) }
	if post_ver != 2   { fail(fmt.tprintf("post hook ran wrong code: VER=%d, expected 2 (obj/new)", post_ver)) }

	// The diff must have flagged State (a field was added: 16 -> 24 bytes) AND Mode (its
	// constants were re-ordered, though its size is unchanged — the enum-aware compare).
	if !post_saw_state { fail("diff did not flag State (added field)") }
	if !post_saw_mode  { fail("diff did not flag Mode (enum constants reordered, same size)") }
	if post_state_old_size != 16 { fail(fmt.tprintf("State old size = %d, expected 16", post_state_old_size)) }
	if post_state_new_size != 24 { fail(fmt.tprintf("State new size = %d, expected 24", post_state_new_size)) }
	// Holder embeds Mode by value but its own layout is unchanged -> transitive flag (B).
	if !post_saw_holder { fail("diff did not flag Holder (embeds a changed nested enum)") }
	// Shape's variants were re-ordered (same size) -> union-aware compare must flag it.
	if !post_saw_shape { fail("diff did not flag Shape (union variants reordered)") }

	// The hot-reload patch must also have taken: reloaded body adds 100.
	probe: State
	PROBE :: 10
	for _ in 0 ..< PROBE {
		work(&probe)
	}
	if probe.n != 100 * PROBE {
		fail(fmt.tprintf("patch did not take: expected %d, got %d", 100 * PROBE, probe.n))
	}

	fmt.printfln("HOOK-TEST: PASS (pre=%d post=%d changed=%d State %d->%d probe=%d)",
		pre_ver, post_ver, post_changed_count, post_state_old_size, post_state_new_size, probe.n)
	os.exit(0)
}
