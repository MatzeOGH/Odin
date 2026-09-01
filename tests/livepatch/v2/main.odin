package livepatch_test

import "core:fmt"
import "core:livepatch"
import "core:os"
import "core:time"

import "dep"

// New imports in this file. `dep` already imports all three, so the packages are in the base
// build's import graph, but none of the procedures below were referenced by it.
import "core:strings"
import mu "vendor:microui"
import rl "vendor:raylib"

// v2 is the patch. Same signature as v1 -- livepatch rejects a changed signature -- but the body
// now calls procedures the base build never referenced:
//   strings.count           Odin stdlib source, absent from the image without preloading
//   mu.rect_overlaps_vec2   vendor Odin source, same
//   rl.ColorToHSV           a foreign C call from patched code
//
// The two Odin procedures are the discriminators: they are genuinely missing from a
// -livepatch-no-preload image, which is what the negative case in run.bat asserts. The raylib
// call is coverage that a foreign call from patched code still resolves -- it is not a
// discriminator, because raylib.lib's members are coarse enough that referencing anything in it
// drags most of the library in regardless. run.bat checks the /WHOLEARCHIVE flag directly.
check :: proc() -> bool {
	if strings.count("livepatch patches patches", "patch") != 3 {
		return false
	}

	if !mu.rect_overlaps_vec2(mu.Rect{0, 0, 10, 10}, mu.Vec2{5, 5}) {
		return false
	}

	hsv := rl.ColorToHSV(rl.Color{255, 0, 0, 255})
	return hsv.z == 1
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
