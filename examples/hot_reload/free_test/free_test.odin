#+build windows
package hot_reload_free_test

// Regression test for the DEFERRED FREE of previously mapped reload blocks (Windows/x64).
//
// Each reload maps fresh code into its own VirtualAlloc'd block. The old block must stay
// mapped until no thread executes in it and nothing still jumps into it; the loader frees
// superseded generations at the next reload after stack-walking every thread. This test
// stresses exactly that: it alternates between TWO distinct reload objects (so every reload
// supersedes the previous generation) RELOADS times WHILE worker threads hammer the hot
// proc (so a generation is often kept one round because a worker is parked inside it, then
// freed once the worker moves on).
//
// It asserts: (1) the process never crashed and every worker advanced across the whole
// window — the safety proof that no block was freed while a thread was still in it; and
// (2) the number of live reload generations stays bounded (old ones are actually reclaimed,
// not leaked). A pre-fix loader (leak every block) would fail (2).

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import win "core:sys/windows"
import hr "core:hot_reload"

State :: struct {
	n: i64,
}

// Baseline body adds 1; run_free_test.ps1 builds two reload variants (+100 and +101) into
// objsA/ and objsB/. Alternating them means each reload's `work` differs from the live one,
// so every reload actually patches (and supersedes the prior generation's block).
work :: proc(s: ^State) {
	s.n += 1
}

N_WORKERS :: 4
RELOADS   :: 200

Worker :: struct {
	state: State,
	iters: u64,
	run:   u32,
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
	fmt.printfln("FREE-TEST: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	fmt.printfln("free-test — pid %d, %d workers, %d reloads (alternating 2 objects)",
		win.GetCurrentProcessId(), N_WORKERS, RELOADS)

	workers: [N_WORKERS]Worker
	handles: [N_WORKERS]win.HANDLE
	for i in 0 ..< N_WORKERS {
		workers[i].run = 1
		handles[i] = win.CreateThread(nil, 0, worker_main, &workers[i], 0, nil)
		if handles[i] == nil {
			fail("CreateThread failed")
		}
	}
	win.Sleep(50) // let the workers spin up

	before: [N_WORKERS]u64
	for i in 0 ..< N_WORKERS {
		before[i] = intrinsics.atomic_load(&workers[i].iters)
	}

	ok_count := 0
	max_live := 0
	for r in 0 ..< RELOADS {
		dir := r % 2 == 0 ? "objsA" : "objsB"
		if hr.apply_dir(dir) {
			ok_count += 1
		}
		if lg := hr.live_generations(); lg > max_live {
			max_live = lg
		}
	}

	for i in 0 ..< N_WORKERS {
		now := intrinsics.atomic_load(&workers[i].iters)
		if now <= before[i] {
			fail(fmt.tprintf("worker %d did not advance (before=%d now=%d) — a live block was likely freed under it", i, before[i], now))
		}
	}

	for i in 0 ..< N_WORKERS {
		intrinsics.atomic_store(&workers[i].run, 0)
	}
	for h in handles {
		win.WaitForSingleObject(h, win.INFINITE)
		win.CloseHandle(h)
	}

	if ok_count == 0 {
		fail("no reload succeeded (are objsA/ and objsB/ present and built with the same manifest?)")
	}

	// The bound: old generations must be reclaimed. Alternating two versions means at most a
	// handful can be transiently retained (current + any a worker is momentarily parked in).
	// A leaking loader would grow this to ~ok_count. Allow generous slack for worker parking.
	live := hr.live_generations()
	LIMIT :: 8
	if max_live > LIMIT {
		fail(fmt.tprintf("live reload generations peaked at %d (> %d) — blocks are leaking, not being freed", max_live, LIMIT))
	}

	fmt.printfln("FREE-TEST: PASS (reloads ok: %d/%d, live generations: peak %d, final %d, bound %d)",
		ok_count, RELOADS, max_live, live, LIMIT)
	os.exit(0)
}
