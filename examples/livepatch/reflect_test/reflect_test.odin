#+build windows
package livepatch_reflect_test

// Verifies the reflection (type_info) refresh across a livepatch: after a reload the exe's
// runtime.type_table is swapped to the reload object's fresh, complete table, so `fmt`/
// `type_info_of` reflect an EDITED struct's new field AND a BRAND-NEW type reached through
// hot code. The runner (run_reflect_test.ps1) builds this at "v1", then compiles an edit that
// adds `y: i64` to Thing and introduces `Extra`, and reloads. Exit 0 = PASS.

import "core:fmt"
import "core:os"
import "core:strings"
import lp "core:livepatch"
import rl "vendor:raylib"

Thing :: struct {
	x: i32,
	// LP_NEW_FIELD
}

// LP_NEW_TYPE

// A package global (resolved to the exe's copy across the reload) that the patched `check`
// writes and the frozen `main` reads.
g_pass: bool
g_ran:  bool

// `check` is livepatchable (not the entry point): after the reload its patched body builds
// the NEW-layout values, so reflection over them must show the new field / new type. The base
// version only asserts the pre-existing field so the "before" call is a valid baseline.
check :: proc() {
	g_ran = true
	th := fmt.aprint(Thing{x = 7}); defer delete(th)
	g_pass = strings.contains(th, "x =")
	// LP_CHECK_NEW
}

main :: proc() {
	// Reference raylib so the program links a LARGE type table — big enough that the RTTI
	// `.odinti` section carries > 0xFFFF relocations (COFF relocation overflow). This makes
	// the test exercise the loader's overflow handling: without it, walking the reload's fresh
	// type graph faults on unrelocated type-info pointers.
	rl.SetRandomSeed(1)

	check()
	if !g_ran { fmt.eprintln("baseline check did not run"); os.exit(1) }

	if !lp.apply_dir() { fmt.eprintln("reload failed"); os.exit(1) }

	g_pass = false
	check()
	if g_pass {
		fmt.println("REFLECT-TEST: PASS (edited field + new type reflect after reload)")
		os.exit(0)
	}
	fmt.println("REFLECT-TEST: FAIL (reflection still shows the old, frozen layout)")
	os.exit(1)
}
