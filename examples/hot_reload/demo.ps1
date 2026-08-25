# Reproduces the hot-reload proof of concept end to end (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\demo.ps1
#
# It builds the demo .exe from the current source, then simulates an "edit" by
# building a modified copy of the package to `hot.obj`, then runs the .exe which
# reloads that object into itself while running.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..')
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'

New-Item -ItemType Directory -Force $work | Out-Null

Write-Host '==> building demo .exe from current source (-hot-reload bakes in the symbol table)'
& $odin build $here -out:(Join-Path $work 'hot_reload.exe') -debug -hot-reload
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> simulating an edit and compiling it to hot.obj'
$v2 = Join-Path $work 'src'
New-Item -ItemType Directory -Force $v2 | Out-Null
Copy-Item (Join-Path $here '*.odin') $v2 -Force
$game = Join-Path $v2 'game.odin'
$text = (Get-Content $game -Raw) -replace 's\.counter \+= s\.step\b', 's.counter += s.step * 10'
$text | Out-File -Encoding utf8 $game
& $odin build $v2 -build-mode:obj -use-single-module -out:(Join-Path $work 'hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running (watch the pid stay the same and the counter continue)'
Push-Location $work
try {
	# Drive the interactive loop non-interactively: tick, tick, reload, tick, tick, quit.
	"t`nt`nr`nt`nt`nq" | & (Join-Path $work 'hot_reload.exe')
}
finally { Pop-Location }
