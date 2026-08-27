# Reproduces the hot-reload proof of concept end to end (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\demo.ps1
#
# It builds the demo .exe from the current source, then simulates an "edit" that
# ADDS a new global and a new procedure (plus changes `update`), compiles that to
# `hot.obj`, and runs the .exe which reloads the object into itself while running.
# Two reloads show that the new global's state persists across reloads.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..')
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'hot.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue   # start from a clean manifest

Write-Host '==> building demo .exe from current source (-hot-reload bakes the table + reserves the arena)'
& $odin build $here -out:(Join-Path $work 'hot_reload.exe') -debug -hot-reload -hot-reload-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> simulating an edit: add a NEW global (reloads) and a NEW proc (bonus), change update'
$v2 = Join-Path $work 'src'
Remove-Item $v2 -Recurse -Force -ErrorAction SilentlyContinue   # drop any stale sources
New-Item -ItemType Directory -Force $v2 | Out-Null
$edited = @'
#+build windows
package hot_reload_demo

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import hr "core:sys/hot_reload"

State :: struct {
	counter: i64,
	step:    i64,
	mirror:  i64,
}

hits: i64

// NEW globals introduced by this reload, living in the compiler-reserved arena so
// their state persists across every subsequent reload. `reloads` is zero-init;
// `threshold` and `limits` carry compile-time CONSTANT initializers that the loader
// writes into the arena exactly once (they then accumulate across further reloads).
reloads: i64
threshold: i64 = 42
limits := [3]i64{10, 20, 30}

// NEW procedure introduced by this reload, called from the patched `update`.
bonus :: proc() -> i64 {
	return 5
}

update :: proc(s: ^State) {
	reloads += 1
	threshold += 1
	s.counter += s.step * 10 + bonus() + limits[1] // limits[1] == 20 proves the aggregate const init
	hits += 2
	s.mirror = threshold // 42 after reload, so 43 on the first tick; persists across the 2nd reload
	// fmt from HOT code: the loader resolves the C-runtime (memcpy/memset/…), _tls_index,
	// and Windows-API symbols this pulls in against the running process, so this no longer
	// crashes. Prints ints via reflection/any straight from the patched-in code.
	fmt.println("   [hot] fmt from hot code -- reloads =", reloads, "threshold =", threshold)
	// COMPOSITE reflection from hot code: `%v` over a user struct + a typeid. With the
	// complete exe type_table + typeid-based type_info lookup, this now prints correctly
	// (previously empty/garbage).
	fmt.printfln("   [hot] composite reflection -- state = %v, typeid = %v", s^, typeid_of(State))
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
				ok := hr.apply(OBJ_PATH)
				fmt.printfln("reload ok: %v", ok)
			case:
				update(&state)
				fmt.printfln("counter = %d   hits = %d   mirror = %d", state.counter, hits, state.mirror)
			}
		}
	}
}
'@
$edited | Out-File -Encoding utf8 (Join-Path $v2 'game.odin')

Write-Host '==> compiling the edit to hot.obj (same manifest, so the new global gets a stable arena slot)'
& $odin build $v2 -build-mode:obj -use-single-module -hot-reload -hot-reload-manifest:$manifest -out:(Join-Path $work 'hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> new-global arena slots recorded in the manifest (offset, type_hash, init-flag+1, name):'
Get-Content $manifest | Select-String 'reloads|threshold|limits|next_free'

Write-Host '==> running (tick, tick, reload, tick, reload, tick, quit)'
Write-Host '    watch mirror (= the new global `threshold`):'
Write-Host '      - first tick after reload 1 shows mirror = 43  => the constant init 42 was applied (not 0), then +1'
Write-Host '      - first tick after reload 2 shows mirror = 44  => threshold PERSISTED (once-only init did not reset it to 42)'
Write-Host '    and counter jumps by 35 per tick (step*10 + bonus 5 + limits[1] 20) => the aggregate const init worked.'
Write-Host '    after each reload the patched update prints a "[hot] fmt from hot code" line => fmt/any works from hot code.'
Push-Location $work
try {
	"t`nt`nr`nt`nr`nt`nq" | & (Join-Path $work 'hot_reload.exe')
}
finally { Pop-Location }
