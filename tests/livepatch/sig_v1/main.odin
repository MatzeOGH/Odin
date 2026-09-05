package sig_test

import "core:fmt"
import "core:livepatch"
import "core:os"

// Regression test for signature-change reloads (Live++ parity; the F8 ABI guard was removed).
// v1 is the base build. v2 changes `add`'s signature from proc(x: int) to proc(x, y: int) AND
// updates its caller `compute` to pass the second argument. Both procs' content hashes change,
// so both are re-patched in the same reload -- the re-patched `compute` marshals the new ABI and
// reaches `add`'s new body. If signature changes were still rejected at build time, the patch
// build would error and `apply_patch` would return false; if only `add` re-patched but a stale
// old-ABI caller reached it, `compute()` would not return the v2 value.
//   v1: add(10)    = 11,  compute() = 11
//   v2: add(10, 5) = 16,  compute() = 16
add :: proc(x: int) -> int {
	return x + 1
}

compute :: proc() -> int {
	return add(10)
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
