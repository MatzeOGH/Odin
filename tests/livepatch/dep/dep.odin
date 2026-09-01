package livepatch_test_dep

// Puts these packages into the base build's import graph without referencing the procedures the
// patch reaches for. This is the premise the feature is scoped to: a reload may import a package
// some other package already imports, not one that nothing imports.

import "core:strings"
import mu "vendor:microui"
import rl "vendor:raylib"

@(private)
ctx: mu.Context

// Referenced by the base build so `core:strings`, `vendor:microui` and `vendor:raylib` are all
// linked in. Nothing here reaches `strings.contains`, `mu.intersect_rects` or `rl.ColorToHSV`.
touch :: proc() -> bool {
	mu.init(&ctx)
	return strings.has_prefix("odin", "o") && rl.GetRandomValue(1, 1) == 1
}
