#+build windows
package unwind_test
// Verifies x64 stack unwinding works THROUGH hot-reloaded code. On x64 there is no
// frame-pointer chain, so RtlCaptureStackBackTrace virtual-unwinds using the function
// tables the loader registers for each reload object (RtlAddFunctionTable on the object's
// .pdata). If a hot proc's unwind info is missing/miswired, the unwinder treats it as a
// leaf frame, reads the wrong return slot, and the walk derails -> far fewer frames.
//
// Differential test:
//   base_depth = frames captured on a PURE-EXE path (main -> exe_probe -> capture)
//   hot_depth  = frames captured after routing through N brand-new HOT procs
//               (main -> hp.deep(hot) -> h1..hN(hot) -> capture)
// Working unwind => hot_depth - base_depth ~= N. Broken => delta collapses (~0-1).
import "core:fmt"
import "core:os"
import win "core:sys/windows"
import hr "core:sys/hot_reload"
import hp "hp"

N :: 6 // hot frames inserted by the reload

// EXE code, never reloaded: captures the current call stack's depth.
// Count the call stack depth using the REAL x64 unwind machinery: RtlLookupFunctionEntry
// + RtlVirtualUnwind. This is what SEH fault handling and debuggers use, and it consults
// the dynamic function tables the hot-reload loader registers (RtlAddFunctionTable). If the
// loader's .pdata/.xdata for hot code is correct, this walks straight through hot frames.
//
// NOTE: Odin's own backtrace (core/debug/trace) uses RtlCaptureStackBackTrace, which does
// NOT cross dynamically-registered code and stops at the first hot frame — a limitation of
// that API, not of the unwind tables. We print both so the difference is visible.
@(optimization_mode="none")
capture :: proc() -> int {
	buf: [96]win.PVOID
	cbt := int(win.RtlCaptureStackBackTrace(0, 96, &buf[0], nil))
	ctx: win.CONTEXT
	win.RtlCaptureContext(&ctx)
	depth := 0
	for depth < 96 {
		ib: win.DWORD64
		fe := win.RtlLookupFunctionEntry(ctx.Rip, &ib, nil)
		if fe == nil { break } // a true leaf or an un-unwindable frame
		hd: rawptr
		ef: win.DWORD64
		win.RtlVirtualUnwind(0, ib, ctx.Rip, fe, &ctx, &hd, &ef, nil)
		if ctx.Rip == 0 { break }
		depth += 1
	}
	fmt.printfln("   [capture] RtlVirtualUnwind depth=%d  (RtlCaptureStackBackTrace=%d)", depth, cbt)
	return depth
}

// EXE code path with ZERO hot frames between main and capture.
@(optimization_mode="none")
exe_probe :: proc() -> int { return capture() }

main :: proc() {
	base_depth := exe_probe()
	fmt.printfln("base (exe-only) stack depth = %d", base_depth)

	if !hr.apply_dir("objs") { fmt.eprintln("UNWIND-TEST: FAIL (reload did not apply)"); os.exit(1) }

	hot_depth := hp.deep(capture)
	fmt.printfln("hot (through %d new hot procs) stack depth = %d  (delta = %d)", N, hot_depth, hot_depth - base_depth)

	if hot_depth - base_depth >= N - 1 {
		fmt.println("UNWIND-TEST: PASS (unwound through all hot frames)")
		os.exit(0)
	}
	fmt.printfln("UNWIND-TEST: FAIL (delta %d < %d: unwinder derailed inside hot code)", hot_depth - base_depth, N - 1)
	os.exit(1)
}
