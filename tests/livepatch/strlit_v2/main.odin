package strlit_test

import "core:fmt"
import "core:livepatch"
import "core:os"

// v2 is the patch: `msg`'s literal is edited to another literal of the same byte
// length. Nothing else changes. `msg`'s content hash must differ from v1's so the
// reload re-patches it and it returns the new bytes.
msg :: proc() -> string {
	return "bbbb"
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: t.exe <odin-exe>")
		os.exit(2)
	}
	applied := livepatch.apply_patch(odin = os.args[1])
	if !applied {
		fmt.eprintln("patch did not apply")
		os.exit(1)
	}
	got := msg()
	if got != "bbbb" {
		fmt.eprintfln("FAIL: same-length string-literal edit not detected: msg()=%q (want \"bbbb\")", got)
		os.exit(1)
	}
	fmt.println("ok")
}
