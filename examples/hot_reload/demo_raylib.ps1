# Reproduces the "call a foreign-library function the base build never referenced"
# hot-reload feature end to end (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\demo_raylib.ps1
#
# The base .exe references ONE vendor:raylib procedure (rl.SetRandomSeed) so raylib.lib
# is statically linked into the image: the linker pulls the whole object member that
# defines SetRandomSeed (raylib's rcore), which also contains GetRandomValue, InitWindow,
# etc. that the base never calls. It is built with /OPT:NOREF,NOICF so the linker keeps
# those unreferenced (function-level COMDAT) functions in the image instead of stripping
# them. Then an "edit" adds a call to GetRandomValue — a raylib procedure the base source
# never referenced — and compiles it to hot.obj. The running .exe reloads that object: the
# loader resolves `GetRandomValue` to its address in the running image via the exe's PDB
# (SymFromNameW), so the patched code calls real raylib. On unpatched Odin the same reload
# aborts ("unresolved symbol in executable code: GetRandomValue").
#
# Requires: -debug base build (PDB), which this script uses.
#
# NOTE ON LINKER FLAGS:
#   /OPT:NOREF  keeps functions that are in a linked member but not referenced by the base
#               source (needed here — GetRandomValue is co-resident with SetRandomSeed).
#   /OPT:NOICF  stops the linker folding identical functions (matches the hot-patch model).
#   To reach a function whose member the base never pulls at all, additionally link the
#   archive whole:  -extra-linker-flags:"/OPT:NOREF,NOICF /WHOLEARCHIVE:raylib.lib"

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..')
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work_rl'
$manifest = Join-Path $work 'hot.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue   # start from a clean manifest

Write-Host '==> building demo .exe from current source (links raylib.lib; -hot-reload auto-adds /OPT:NOREF,NOICF to keep unreferenced raylib functions)'
# -hot-reload implies -debug and auto-adds /OPT:NOREF,NOICF, so neither is passed here.
# (Add -extra-linker-flags:"/WHOLEARCHIVE:raylib.lib" only to reach a member the base never pulls.)
& $odin build $here -out:(Join-Path $work 'hot_reload.exe') -hot-reload -hot-reload-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }
if (-not (Test-Path (Join-Path $work 'hot_reload.pdb'))) { throw 'no PDB produced next to the exe (need -debug)' }

Write-Host '==> simulating an edit: `update` now calls rl.GetRandomValue, which the base source never referenced'
$v2 = Join-Path $work 'src'
Remove-Item $v2 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $v2 | Out-Null
$edited = @'
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
	mirror:  i64,
}

hits: i64

update :: proc(s: ^State) {
	s.counter += s.step
	hits += 2
	// NEW foreign call: GetRandomValue was never referenced by the base source, so it is
	// not exported and not in the baked table. The loader resolves it via the exe's PDB.
	r := rl.GetRandomValue(1, 100)
	s.mirror = i64(r)
	fmt.println("   [hot] raylib from hot code -- GetRandomValue(1,100) =", r)
}

OBJ_PATH :: "hot.obj"

main :: proc() {
	state := State{counter = 0, step = 1}
	pid := win.GetCurrentProcessId()

	rl.SetRandomSeed(1)

	fmt.printfln("hot-reload demo — pid %d", pid)
	fmt.println("commands:  [enter]/t = tick    r = reload from hot.obj    q = quit")

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

Write-Host '==> compiling the edit to hot.obj (same manifest)'
& $odin build $v2 -build-mode:obj -use-single-module -hot-reload -hot-reload-manifest:$manifest -out:(Join-Path $work 'hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running (tick, reload, tick, quit)'
Write-Host '    after the reload, expect:  reload ok: true  and a "[hot] raylib from hot code -- GetRandomValue(1,100) = N" line'
Write-Host '    (on unpatched Odin the reload instead prints "unresolved symbol in executable code: GetRandomValue" and returns false)'
Push-Location $work
try {
	"t`nr`nt`nq" | & (Join-Path $work 'hot_reload.exe')
}
finally { Pop-Location }
