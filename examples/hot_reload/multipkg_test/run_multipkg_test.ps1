# Automated test: MULTI-PACKAGE hot reload — one reload patches every user package that
# changed, across a cross-package call chain, while an unchanged package is not re-emitted.
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\multipkg_test\run_multipkg_test.ps1
#
# Builds the .exe (4 user packages: pkgc -> pkgb -> pkga, plus independent pkgd), then edits
# pkga/pkgb/pkgc (NOT pkgd, NOT the main package) and compiles a SEPARATE-MODULES reload set.
# Asserts: (a) only the changed packages produced objects (incremental emission), and (b) the
# running exe reloads the whole set and every edited body takes effect. Exit 0 = PASS.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'multipkg.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
if (Test-Path $manifest) { Remove-Item $manifest }

Write-Host '==> building multipkg .exe (-hot-reload, base versions)'
& $odin build $here -out:(Join-Path $work 'multipkg.exe') -hot-reload -hot-reload-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> editing pkga (1->2), pkgb (+10->+20), pkgc (+100->+200); pkgd + main UNCHANGED'
$src = Join-Path $work 'src'
if (Test-Path $src) { Remove-Item $src -Recurse -Force }
New-Item -ItemType Directory -Force $src | Out-Null
Copy-Item (Join-Path $here 'multipkg.odin') $src
foreach ($p in 'pkga','pkgb','pkgc','pkgd') { Copy-Item (Join-Path $here $p) $src -Recurse }

((Get-Content -Raw "$src\pkga\pkga.odin") -replace 'return 1\b',   'return 2')   | Out-File -Encoding utf8 "$src\pkga\pkga.odin"
((Get-Content -Raw "$src\pkgb\pkgb.odin") -replace '\+ 10\b',      '+ 20')       | Out-File -Encoding utf8 "$src\pkgb\pkgb.odin"
((Get-Content -Raw "$src\pkgc\pkgc.odin") -replace '\+ 100\b',     '+ 200')      | Out-File -Encoding utf8 "$src\pkgc\pkgc.odin"

Write-Host '==> compiling the edit to a separate-modules reload set (same manifest)'
$objs = Join-Path $work 'objs'
if (Test-Path $objs) { Remove-Item $objs -Recurse -Force }
New-Item -ItemType Directory -Force $objs | Out-Null
& $odin build $src -build-mode:obj -hot-reload -hot-reload-manifest:$manifest -out:(Join-Path $objs 'hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> checking incremental emission: only changed user packages produced objects'
$emitted = (Get-ChildItem "$objs\*.obj" | ForEach-Object { $_.Name }) -join ' '
Write-Host "    emitted: $emitted"
$fail = $false
foreach ($must in 'hot-pkga.obj','hot-pkgb.obj','hot-pkgc.obj') {
	if ($emitted -notmatch [regex]::Escape($must)) { Write-Host "    MISSING expected $must" -ForegroundColor Red; $fail = $true }
}
foreach ($mustnot in 'hot-pkgd.obj','hot-hot_reload_multipkg.obj') {
	if ($emitted -match [regex]::Escape($mustnot)) { Write-Host "    UNEXPECTED $mustnot (unchanged package should be skipped)" -ForegroundColor Red; $fail = $true }
}
if ($fail) { Write-Host '==> RESULT: FAIL (incremental-emission check)' -ForegroundColor Red; exit 1 }
Write-Host '    OK: pkga/pkgb/pkgc emitted; pkgd + main skipped'

Write-Host '==> running (the exe reloads objs\ and asserts the patched values)'
Push-Location $work
try {
	& (Join-Path $work 'multipkg.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green }
else             { Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red }
exit $code
