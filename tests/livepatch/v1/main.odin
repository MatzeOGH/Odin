package livepatch_test

import "core:fmt"
import "core:livepatch"
import "core:os"
import "core:time"

import "dep"

// v1 is the base build: `check` calls nothing, so the procedures v2 reaches for are absent from
// the image unless the base build preloaded everything its imports could reach.
check :: proc() -> bool {
	return false
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: t.exe <odin-exe> [--expect-fail]")
		os.exit(2)
	}
	odin_exe := os.args[1]
	expect_fail := len(os.args) > 2 && os.args[2] == "--expect-fail"

	if !dep.touch() {
		fmt.eprintln("dependency smoke test failed")
		os.exit(2)
	}

	start := time.tick_now()
	applied := livepatch.apply_patch(odin = odin_exe)
	fmt.printfln("apply_patch=%v first_apply=%v", applied, time.tick_since(start))

	ok := applied && check()
	if expect_fail {
		if ok {
			fmt.eprintln("expected the patch to fail without preloading, but it applied")
			os.exit(1)
		}
		fmt.println("failed as expected")
		return
	}
	if !ok {
		fmt.eprintln("patch did not apply, or the patched check() returned false")
		os.exit(1)
	}
	fmt.println("ok")
}
