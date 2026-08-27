#+build windows
package hot_reload_mt_test

// Automated regression test for THREAD-SAFE hot patching (Windows / x64).
//
// Unlike the interactive demo, this program drives itself and exits 0 on success /
// non-zero on failure, so it can run unattended (see run_mt_test.ps1).
//
// It spawns N worker threads that hammer the `@(hot_reload) work` procedure in a
// tight loop, then reloads `mt_hot.obj` into the process RELOADS times WHILE the
// workers are running — the exact race the thread-safe patcher must survive. It then
// asserts: (1) the process never crashed, (2) every worker kept running across the
// whole reload window, and (3) the patch actually took effect (the reloaded body
// adds 100 instead of 1).

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import win "core:sys/windows"
import hr "core:sys/hot_reload"

State :: struct {
	n: i64,
}

// The procedure under test. The BASELINE body adds 1; run_mt_test.ps1 builds the
// reload object from an edited copy whose body adds 100, so a successful patch is
// directly observable. Workers call this concurrently while the main thread reloads.
// Under -hot-reload every procedure is hot-reloadable automatically (no tag needed).
work :: proc(s: ^State) {
	s.n += 1
}

N_WORKERS :: 4
RELOADS   :: 200
OBJ_PATH  :: "mt_hot.obj"

Worker :: struct {
	state: State,
	iters: u64, // bumped atomically each loop iteration; main watches it advance
	run:   u32, // 1 while the worker should keep looping; atomically cleared to stop
}

worker_main :: proc "system" (param: rawptr) -> win.DWORD {
	context = runtime.default_context()
	w := (^Worker)(param)
	for intrinsics.atomic_load(&w.run) != 0 {
		work(&w.state)
		intrinsics.atomic_add(&w.iters, 1)
	}
	return 0
}

fail :: proc(reason: string) -> ! {
	fmt.printfln("MT-TEST: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	pid := win.GetCurrentProcessId()
	fmt.printfln("mt-test — pid %d, %d workers, %d reloads", pid, N_WORKERS, RELOADS)

	workers: [N_WORKERS]Worker
	handles: [N_WORKERS]win.HANDLE
	for i in 0 ..< N_WORKERS {
		workers[i].run = 1
		handles[i] = win.CreateThread(nil, 0, worker_main, &workers[i], 0, nil)
		if handles[i] == nil {
			fail("CreateThread failed")
		}
	}

	// Let the workers spin up before we start patching under them.
	win.Sleep(50)

	before: [N_WORKERS]u64
	for i in 0 ..< N_WORKERS {
		before[i] = intrinsics.atomic_load(&workers[i].iters)
	}

	// The stress: reload the object many times while every worker is executing `work`.
	ok_count := 0
	for _ in 0 ..< RELOADS {
		if hr.apply(OBJ_PATH) {
			ok_count += 1
		}
	}

	// Every worker must have made progress across the reload window — if one crashed
	// or was corrupted by a torn patch, its iteration count would have frozen.
	for i in 0 ..< N_WORKERS {
		now := intrinsics.atomic_load(&workers[i].iters)
		if now <= before[i] {
			fail(fmt.tprintf("worker %d did not advance (before=%d now=%d) — crashed or stalled", i, before[i], now))
		}
	}

	// Stop the workers and join.
	for i in 0 ..< N_WORKERS {
		intrinsics.atomic_store(&workers[i].run, 0)
	}
	for h in handles {
		win.WaitForSingleObject(h, win.INFINITE)
		win.CloseHandle(h)
	}

	if ok_count == 0 {
		fail("no reload succeeded (is mt_hot.obj present and built with the same manifest?)")
	}

	// Prove the patch actually took: with the reloaded (+100) body, a fresh probe must
	// accumulate in steps of 100, not 1.
	probe: State
	PROBE :: 10
	for _ in 0 ..< PROBE {
		work(&probe)
	}
	if probe.n != 100 * PROBE {
		fail(fmt.tprintf("post-reload behavior wrong: expected %d, got %d (patch did not take)", 100 * PROBE, probe.n))
	}

	fmt.printfln("MT-TEST: PASS (reloads ok: %d/%d, probe = %d)", ok_count, RELOADS, probe.n)
	os.exit(0)
}
