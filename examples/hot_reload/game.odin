#+build windows
package hot_reload

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

State :: struct {
	counter: i64,
	step:    i64,
}

// A package GLOBAL — state that lives in the .exe's data segment. The hot
// procedure below reads and writes it; when the object is reloaded, the loader
// resolves that reference to *this exe's* copy of `hits`, so its value carries
// across reloads. (A DLL-swap approach gets its own separate copy and cannot do
// this — resolving relocations against the running process is what makes it work.)
hits: i64

// A `@(hot_reload)` procedure. With the exe built `-hot-reload`, its body may call
// the standard library and read/write globals — the loader relocates it against
// the running process. Edit the arithmetic/message, rebuild the object (see
// README.md), then type `r` in the running program to replace it in place.
@(hot_reload)
update :: proc(s: ^State) {
	s.counter += s.step * 10 // host-owned state, via pointer
	hits += 2           // global state, resolved to the exe's copy
}

OBJ_PATH :: "hot.obj"

main :: proc() {
	state := State{counter = 0, step = 1}
	pid := win.GetCurrentProcessId()

	fmt.printfln("hot-reload demo — pid %d", pid)
	fmt.println("commands:  [enter]/t = tick    r = reload from hot.obj    q = quit")
	fmt.println("edit `update` in game.odin, rebuild the object, then press r.")

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
			case "r":
				ok := load_and_patch(OBJ_PATH, []Hot_Func{{"update", rawptr(update)}})
				fmt.printfln("reload ok: %v", ok)
			case: // empty line or "t": advance the simulation
				update(&state)
				fmt.printfln("counter = %d   hits = %d", state.counter, hits)
			}
		}
	}
}
