# Reproduces the hot-reload proof of concept end to end (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\demo.ps1
#
# Hermetic: it writes a v1 BASE program and a v2 EDIT into .work\src\, so it does not depend on
# the current game.odin. It builds the exe from the base, then simulates an "edit" that ADDS a
# new global and a new procedure (and changes `update`), rebuilds the reload PATCH with the
# single `-hot-reload-patch` command, and runs the exe which reloads the patch into itself while
# running. Two reloads show the new global's state persists across reloads.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Resolve-Path (Join-Path $here '..\..')
$odin = Join-Path $repo 'odin.exe'
$work = Join-Path $here '.work'
$src  = Join-Path $work 'src'

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue   # start clean (exe, manifest, hot_objs)
New-Item -ItemType Directory -Force $src | Out-Null

# ---- v1 BASE: the program the exe is built from ------------------------------------------------
$base = @'
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
	mirror:  i64, // the reload stashes a new global here so the host can observe it
}

hits: i64

update :: proc(s: ^State) {
	fmt.println("   [update] v1")
	s.counter += s.step
	hits += 2
}

main :: proc() {
	state := State{counter = 0, step = 1}
	pid := win.GetCurrentProcessId()

	fmt.printfln("hot-reload demo — pid %d", pid)
	fmt.println("commands:  [enter]/t = tick    r = reload from hot_objs\\    q = quit")

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
				ok := hr.apply_dir() // default dir "hot_objs"
				fmt.printfln("reload ok: %v", ok)
			case:
				update(&state)
				fmt.printfln("counter = %d   hits = %d   mirror = %d", state.counter, hits, state.mirror)
			}
		}
	}
}
'@
$base | Out-File -Encoding utf8 (Join-Path $src 'game.odin')

Write-Host '==> building demo .exe from the v1 base (-hot-reload reserves the arena; implies -debug + auto /OPT:NOREF,NOICF)'
Push-Location $src
try {
	& $odin build . -out:hot_reload.exe -hot-reload
	if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }
}
finally { Pop-Location }

# ---- v2 EDIT: add a NEW global (reloads) + NEW proc (bonus), change update ---------------------
Write-Host '==> simulating an edit: add a NEW global (reloads) and a NEW proc (bonus), change update'
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

main :: proc() {
	state := State{counter = 0, step = 1}
	pid := win.GetCurrentProcessId()

	fmt.printfln("hot-reload demo — pid %d", pid)
	fmt.println("commands:  [enter]/t = tick    r = reload from hot_objs\\    q = quit")

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
				ok := hr.apply_dir()
				fmt.printfln("reload ok: %v", ok)
			case:
				update(&state)
				fmt.printfln("counter = %d   hits = %d   mirror = %d", state.counter, hits, state.mirror)
			}
		}
	}
}
'@
$edited | Out-File -Encoding utf8 (Join-Path $src 'game.odin')

Write-Host '==> rebuilding the reload PATCH with one command: odin build . -hot-reload-patch'
# Same directory as the exe build, so no -build-mode/-out/manifest to align: -hot-reload-patch
# emits into .\hot_objs\ (created + stale *.obj cleared) and reuses the default manifest, and
# the running exe reloads it via apply_dir() (default dir "hot_objs").
Push-Location $src
try {
	& $odin build . -hot-reload-patch
	if ($LASTEXITCODE -ne 0) { throw 'patch build failed' }
}
finally { Pop-Location }

Write-Host '==> new-global arena slots recorded in the manifest (offset, type_hash, init-flag+1, name):'
Get-Content (Join-Path $src 'odin-hot-reload.manifest') | Select-String 'reloads|threshold|limits|next_free'

Write-Host '==> running (tick, tick, reload, tick, reload, tick, quit)'
Write-Host '    watch mirror (= the new global `threshold`):'
Write-Host '      - first tick after reload 1 shows mirror = 43  => the constant init 42 was applied (not 0), then +1'
Write-Host '      - first tick after reload 2 shows mirror = 44  => threshold PERSISTED (once-only init did not reset it to 42)'
Write-Host '    and counter jumps by 35 per tick (step*10 + bonus 5 + limits[1] 20) => the aggregate const init worked.'
Write-Host '    after each reload the patched update prints a "[hot] fmt from hot code" line => fmt/any works from hot code.'
Push-Location $src
try {
	"t`nt`nr`nt`nr`nt`nq" | & (Join-Path $src 'hot_reload.exe')
}
finally { Pop-Location }
