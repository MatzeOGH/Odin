$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$env:ODIN_ROOT = $repo
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'uw.manifest'
New-Item -ItemType Directory -Force $work | Out-Null
if (Test-Path $manifest) { Remove-Item $manifest }

Write-Host '==> build exe (base: hp.deep has no hot frames)'
& $odin build $here -out:(Join-Path $work 'uw.exe') -livepatch -livepatch-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> reload edit: hp.deep now threads through 6 BRAND-NEW hot procs h1..h6'
$src = Join-Path $work 'src'
if (Test-Path $src) { Remove-Item $src -Recurse -Force }
New-Item -ItemType Directory -Force $src | Out-Null
Copy-Item (Join-Path $here 'main.odin') $src
Copy-Item (Join-Path $here 'hp') $src -Recurse
@'
package hp
// Reload version: 6 new non-leaf hot procs, each with a real stack frame (local + call),
// so a missing/miswired unwind entry would derail the walk. deep -> h1 -> ... -> h6 -> capture.
Cap :: proc() -> int
h6 :: proc(c: Cap) -> int { pad: [8]int; pad[0] = c(); return pad[0] + 6 }
h5 :: proc(c: Cap) -> int { pad: [8]int; pad[0] = h6(c); return pad[0] + 5 }
h4 :: proc(c: Cap) -> int { pad: [8]int; pad[0] = h5(c); return pad[0] + 4 }
h3 :: proc(c: Cap) -> int { pad: [8]int; pad[0] = h4(c); return pad[0] + 3 }
h2 :: proc(c: Cap) -> int { pad: [8]int; pad[0] = h3(c); return pad[0] + 2 }
h1 :: proc(c: Cap) -> int { pad: [8]int; pad[0] = h2(c); return pad[0] + 1 }
deep :: proc(capture: proc() -> int) -> int { return h1(capture) - 21 } // strip the +1..+6 addends
'@ | Out-File -Encoding utf8 "$src\hp\hp.odin"

Write-Host '==> compile separate-modules reload set'
$objs = Join-Path $work 'objs'
if (Test-Path $objs) { Remove-Item $objs -Recurse -Force }
New-Item -ItemType Directory -Force $objs | Out-Null
& $odin build $src -build-mode:obj -livepatch -livepatch-manifest:$manifest -out:(Join-Path $objs 'hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> run'
Push-Location $work
try { & (Join-Path $work 'uw.exe'); $code = $LASTEXITCODE } finally { Pop-Location }
if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green } else { Write-Host "==> RESULT: FAIL ($code)" -ForegroundColor Red }
exit $code
