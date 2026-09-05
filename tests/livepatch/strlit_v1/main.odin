package strlit_test

import "core:fmt"
import "core:livepatch"
import "core:os"

// Regression test for the constant-identity fix in lb_livepatch_proc_content_hash.
// v1 is the base build; v2 edits `msg`'s literal to another literal of the SAME
// length ("aaaa" -> "bbbb"). That change touches no length and no call graph, so
// the only thing that can flip `msg`'s content hash is the literal's bytes. If the
// hash does not change, `msg` is not re-patched and still returns "aaaa".
msg :: proc() -> string {
	return "aaaa"
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
