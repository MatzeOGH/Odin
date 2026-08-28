#+build windows
package livepatch

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"

// Applies a single reload object file to the running process.
apply :: proc(obj_path: string) -> bool {
	when !ODIN_LIVEPATCH { return false }
	return apply_many({obj_path})
}

// Applies every .obj in a directory as one reload.
apply_dir :: proc(dir := "hot_objs") -> bool {
	when !ODIN_LIVEPATCH { return false }

	scratch: runtime.Arena
	_ = runtime.arena_init(&scratch, 0, runtime.heap_allocator())
	context.temp_allocator = runtime.arena_allocator(&scratch)
	defer runtime.arena_destroy(&scratch)

	pattern := fmt.tprintf("%s/*.obj", dir)
	matches, err := filepath.glob(pattern, context.temp_allocator)

	if err != nil || len(matches) == 0 {
		fmt.eprintfln("[livepatch] apply_dir: no .obj files found in %q", dir)
		return false
	}
	return apply_many(matches)
}

// Rebuilds the reload objects by invoking the Odin compiler on the exe's own package.
build_patch :: proc(odin := "odin", env: []string = nil) -> bool {
	when !ODIN_LIVEPATCH { return false }

	scratch: runtime.Arena
	_ = runtime.arena_init(&scratch, 0, runtime.heap_allocator())
	context.temp_allocator = runtime.arena_allocator(&scratch)
	defer runtime.arena_destroy(&scratch)

	return lp_run_patch_build(odin, filepath.dir(os.args[0]), env)
}

// Rebuilds the reload objects and applies them in one step.
apply_patch :: proc(odin := "odin", env: []string = nil) -> bool {
	when !ODIN_LIVEPATCH { return false }

	scratch: runtime.Arena
	_ = runtime.arena_init(&scratch, 0, runtime.heap_allocator())
	context.temp_allocator = runtime.arena_allocator(&scratch)
	defer runtime.arena_destroy(&scratch)

	pkg_dir := filepath.dir(os.args[0])
	if !lp_run_patch_build(odin, pkg_dir, env) {
		return false
	}
	objs_dir, _ := filepath.join({pkg_dir, "hot_objs"}, context.temp_allocator)
	return apply_dir(objs_dir)
}


Async_Build :: struct {
	th:       ^thread.Thread,
	done:     b32, // atomic: set by the worker when the build finishes
	ok:       b32, // valid once done
	odin:     string,
	env:      []string,
	objs_dir: string, // resolved at spawn so apply doesn't re-derive it
}


// Starts an async patch build on a worker thread, returning a handle to poll.
build_patch_async :: proc(odin := "odin", env: []string = nil) -> ^Async_Build {
	when !ODIN_LIVEPATCH { return nil }

	if _, ok := intrinsics.atomic_compare_exchange_strong(&_lp_build_busy, false, true); !ok {
		fmt.eprintln("[livepatch] a patch build/apply is already in progress.")
		return nil
	}

	ab := new(Async_Build)
	ab.odin = strings.clone(odin)
	ab.env = env
	ab.objs_dir = filepath.join({filepath.dir(os.args[0]), "hot_objs"}) or_else strings.clone("hot_objs")

	ab.th = thread.create_and_start_with_poly_data(ab, proc(ab: ^Async_Build) {
		ok := build_patch(ab.odin, ab.env)
		intrinsics.atomic_store(&ab.ok, b32(ok))
		intrinsics.atomic_store(&ab.done, true)
	})
	return ab
}

// Polls an async build, once finished, applies it and cleans up, reporting whether it applied.
try_apply_async :: proc(ab: ^Async_Build) -> (applied: bool, still_building: bool) {
	when !ODIN_LIVEPATCH { return false, false }
	if ab == nil {
		return false, false
	}
	if intrinsics.atomic_load(&ab.done) == false {
		return false, true
	}
	thread.join(ab.th)
	if bool(ab.ok) {
		applied = apply_dir(ab.objs_dir)
	}
	thread.destroy(ab.th)
	delete(ab.odin)
	delete(ab.objs_dir)
	free(ab)
	intrinsics.atomic_store(&_lp_build_busy, false)
	return applied, false
}

// Runs `odin build <pkg_dir> -livepatch-patch`, streaming its output; returns success.
@(private)
lp_run_patch_build :: proc(odin: string, pkg_dir: string, env: []string) -> bool {
	cmd := []string{odin, "build", pkg_dir, "-livepatch-patch"}

	fmt.printfln("[livepatch] rebuilding patch: %s build %q -livepatch-patch", odin, pkg_dir)
	state, sout, serr, err := os.process_exec({command = cmd, env = env}, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("[livepatch] build failed to launch %q (is it on PATH?): %v", odin, err)
		return false
	}
	if len(sout) > 0 { fmt.print(string(sout)) }
	if len(serr) > 0 { fmt.eprint(string(serr)) }
	if state.exit_code != 0 {
		fmt.eprintfln("[livepatch] patch build failed (exit %d) running code left as-is", state.exit_code)
		return false
	}
	return true
}
