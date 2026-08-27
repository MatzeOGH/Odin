$ErrorActionPreference = 'Stop'
$env:ODIN_ROOT = 'C:\Users\matth\Documents\Projects\Odin'
$here     = $PSScriptRoot
$repo     = 'C:\Users\matth\Documents\Projects\Odin'
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'ng.manifest'
New-Item -ItemType Directory -Force $work | Out-Null
if (Test-Path $manifest) { Remove-Item $manifest }

Write-Host '==> build exe (base, no new global)'
& $odin build $here -out:(Join-Path $work 'ng.exe') -hot-reload -hot-reload-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> reload edit: pkga.bump now references a BRAND-NEW package global `ticks`'
$src = Join-Path $work 'src'
if (Test-Path $src) { Remove-Item $src -Recurse -Force }
New-Item -ItemType Directory -Force $src | Out-Null
Copy-Item (Join-Path $here 'main.odin') $src
Copy-Item (Join-Path $here 'pkga') $src -Recurse
@'
package pkga
// Reload version: introduces a new package global referenced from this package's proc.
ticks: int
bump :: proc() -> int { ticks += 1; return ticks }
'@ | Out-File -Encoding utf8 "$src\pkga\pkga.odin"

Write-Host '==> compile separate-modules reload set (this is where the unresolved-symbol bug hit)'
$objs = Join-Path $work 'objs'
if (Test-Path $objs) { Remove-Item $objs -Recurse -Force }
New-Item -ItemType Directory -Force $objs | Out-Null
& $odin build $src -build-mode:obj -hot-reload -hot-reload-manifest:$manifest -out:(Join-Path $objs 'hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> run'
Push-Location $work
try { & (Join-Path $work 'ng.exe'); $code = $LASTEXITCODE } finally { Pop-Location }
if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green } else { Write-Host "==> RESULT: FAIL ($code)" -ForegroundColor Red }
exit $code
