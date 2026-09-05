package sig_test

import "core:fmt"
import "core:livepatch"
import "core:os"

// v2 is the patch: `add` gains a second parameter (a signature/ABI change) and `compute` is
// updated to pass it. Both re-patch together; `compute()` now returns 16 through the new ABI.
//   v2: add(10, 5) = 16,  compute() = 16
add :: proc(x: int, y: int) -> int {
	return x + y + 1
}

compute :: proc() -> int {
	return add(10, 5)
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: t.exe <odin-exe>")
		os.exit(2)
	}
	applied := livepatch.apply_patch(odin = os.args[1])
	if !applied {
		fmt.eprintln("patch did not apply (a signature change must NOT be rejected)")
		os.exit(1)
	}
	got := compute()
	if got != 16 {
		fmt.eprintfln("FAIL: signature-change reload: compute()=%d (want 16)", got)
		os.exit(1)
	}
	fmt.println("ok")
}
