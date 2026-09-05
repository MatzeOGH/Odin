#+build windows
package newglobal_test
// Repro: a brand-new global introduced by the reload, referenced across packages.
import "core:fmt"
import "core:os"
import lp "core:livepatch"
import a "pkga"
main :: proc() {
	base := a.bump() // base: returns 100, no new global yet
	fmt.printfln("base:  a.bump()=%d", base)
	if !lp.apply_dir("objs") { fmt.eprintln("NEWGLOBAL-TEST: FAIL (reload did not apply)"); os.exit(1) }
	// After reload pkga.bump touches a NEW package global `ticks` that did not exist in the exe.
	r1 := a.bump()
	r2 := a.bump()
	fmt.printfln("after: a.bump()=%d then %d (new global ticks)", r1, r2)
	if r1 == 1 && r2 == 2 { fmt.println("NEWGLOBAL-TEST: PASS"); os.exit(0) }
	fmt.printfln("NEWGLOBAL-TEST: FAIL (r1=%d r2=%d)", r1, r2); os.exit(1)
}
