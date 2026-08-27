#+build windows
package hot_reload_demo

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import hr "core:sys/hot_reload"
import rl "vendor:raylib"

State :: struct {
	counter: i64,
	step:    i64,
	mirror:  i64, // hot code mirrors a new global here so the host can observe it
}

// A package GLOBAL in the exe's data segment. `update` reads/writes it; on reload
// the loader resolves the reference to *this exe's* copy, so its value carries
// across reloads. (A DLL-swap approach gets a separate copy and cannot do this.)
hits: i64


new_int := 86

// With the exe built `-hot-reload`, EVERY procedure is hot-reloadable automatically (no
// tag needed). Its body may call other procedures, read/write globals, reference brand-new
// globals and procedures that did not exist when the exe was built, and — since the loader
// resolves C-runtime and Windows-API symbols against the running process — call `fmt` and
// the rest of the standard library. Edit it (see demo.ps1 / README.md), rebuild the object,
// then press `r`; the loader patches only the procedures whose code changed.
update :: proc(s: ^State) {
	// ---- EDIT HERE, then `odin build . -hot-reload-patch` (ctrl-alt-r) and press `r` ----
	// Try: change the numbers, print something new, add a global/proc above and use it.
	fmt.println("   [update] v1")   // bump "v1" -> "v2" to see the reload instantly
	
	s.counter += s.step             // host-owned state, via pointer
	hits += 2                       // global state, resolved to the exe's copy
	// Foreign-library call from a `vendor:raylib` package that the exe already links
	// (see `main`). A reload may ADD calls to *other* raylib procedures this source has
	// not referenced before — e.g. `rl.GetRandomValue(1, 100)` — and the loader resolves
	// them to their address in the running image via the exe's PDB. See demo_raylib.ps1.
	// ----------------------------------------------------------------------------------



	a := rl.GetRandomValue(1,100)
	fmt.println("hello world")
	neo = neo + 1
	//fmt.println(v)
	//rl.InitWindow(600, 500, "hello")
	//rl.CloseWindow()
	//boo : BOO
	//fmt.println(boo)

	
	boo := BOO {
		a = 59
	}
	fmt.println(boo)
	
}


BOO :: struct {
	a : i8
}
/*
BOO :: struct {

}*/

@(pre_patch_hook)
save :: proc(changed: []hr.Type_Change) {
	fmt.println("pre_patch_hook")
}

// @(post_patch_hook): NEW code. If State's layout changed, build a fresh new-layout
// State and deserialize the saved fields into it by name, then swap the host pointer.
@(post_patch_hook)
load :: proc(changed: []hr.Type_Change) {
	fmt.println("post_patch_hook")
}


@(thread_local) v:int
@(thread_local) neo : int

// The reload set's per-package objects live in `hot_objs\` (the default `-hot-reload-patch`
// output dir, see recompile.ps1); `hr.apply_dir()` reads that directory by default.

main :: proc() {
	state := State{counter = 0, step = 1}
	pid := win.GetCurrentProcessId()

	// Reference one `vendor:raylib` procedure so the exe statically links raylib.lib
	// (pulling its object member into the image). A hot reload can then call *other*
	// raylib procedures this source never referenced — the loader resolves them via the
	// exe's PDB. `SetRandomSeed` needs no window/GPU, so this stays a console demo.
	rl.SetRandomSeed(1)

	fmt.printfln("hot-reload demo — pid %d", pid)
	fmt.println("commands:  [enter]/t = tick    b = rebuild+reload    r = reload only    q = quit")
	fmt.println("edit `update` in game.odin, then press `b` (self-contained: it runs the")
	fmt.println("`-hot-reload-patch` build for you and reloads) — or build by hand and press `r`.")

	buf: [256]u8
	for {
		fmt.print("> ")
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n == 0 {
			break
		}
		chunk := string(buf[:n])
		for line in strings.split_lines_iterator(&chunk) {
			switch strings.trim_space(line) {
			case "q":
				return
			case "b":
				// Self-contained: rebuild the patch from within this process, then reload.
				// odin is two dirs up from the package (repo root); run.ps1 runs us from here.
				ok := hr.apply_patch(odin = "..\\..\\odin.exe")
				fmt.printfln("rebuild+reload ok: %v", ok)
			case "r":
				ok := hr.apply_dir() // default dir "hot_objs"
				fmt.printfln("reload ok: %v", ok)
			case: // empty line or "t": advance the simulation
				update(&state)
				fmt.printfln("counter = %d   hits = %d   mirror = %d", state.counter, hits, state.mirror)
			}
		}
	}
}
