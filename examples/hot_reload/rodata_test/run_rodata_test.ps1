# Automated regression test for @(rodata) and #load hot reload (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\rodata_test\run_rodata_test.ps1
#
# Builds the test .exe (-hot-reload), simulates an "edit" that changes a @(rodata) value
# (PALETTE[0]) and the #load'd asset.txt but NO procedure body, compiles that to
# rodata_hot.obj, and runs the .exe. The .exe reads the data, reloads the object, and
# asserts the immutable data was refreshed while an ordinary mutable global persisted.
# Exit code is propagated: 0 = PASS, non-zero = FAIL.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'rodata.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue   # start from a clean manifest

Write-Host '==> building rodata-test .exe (-hot-reload -debug)'
& $odin build $here -out:(Join-Path $work 'rodata_test.exe') -debug -hot-reload -hot-reload-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> simulating a DATA-ONLY edit: PALETTE[0] 0x11111111 -> 0xAAAAAAAA, asset.txt + assets/ reloaded'
$src = Join-Path $work 'src'
Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $src | Out-Null
New-Item -ItemType Directory -Force (Join-Path $src 'assets') | Out-Null
$edited = (Get-Content -Raw (Join-Path $here 'rodata_test.odin')) -replace '0x11111111', '0xAAAAAAAA'
# Also change the #hash string literal so its compile-time hash differs on reload.
$edited = $edited -replace 'interesting-string', 'reloaded-string'
if ($edited -notmatch '0xAAAAAAAA' -or $edited -notmatch 'reloaded-string') { throw 'edit substitution failed (source marker changed?)' }
$edited | Out-File -Encoding utf8 (Join-Path $src 'rodata_test.odin')
# The reload object's #load / #load_directory resolve paths relative to the edited source dir.
# The asset is a DIFFERENT length than the baseline, to exercise the "#load size change is
# free" path (the exe's slice header is repointed at the object's fresh blob).
[System.IO.File]::WriteAllText((Join-Path $src 'asset.txt'), 'RELOADED_ASSET_v2_IS_NOTABLY_LONGER_THAN_BASELINE')
[System.IO.File]::WriteAllText((Join-Path $src 'assets\a.txt'), 'DIR_RELOADED')

Write-Host '==> compiling the edit to rodata_hot.obj (same manifest)'
& $odin build $src -build-mode:obj -use-single-module -hot-reload -hot-reload-manifest:$manifest -out:(Join-Path $work 'rodata_hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running the test (read data, reload, assert refresh + preservation)'
Push-Location $work
try {
	& (Join-Path $work 'rodata_test.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) {
	Write-Host '==> RESULT: PASS' -ForegroundColor Green
} else {
	Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red
}
exit $code
