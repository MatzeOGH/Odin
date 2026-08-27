# Automated regression test for thread-safe hot patching (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\mt_test\run_mt_test.ps1
#
# Builds the test .exe (-hot-reload), simulates an "edit" that changes the
# hot-reloaded `work` body from `s.n += 1` to `s.n += 100`, compiles that to
# mt_hot.obj, and runs the .exe. The .exe spawns worker threads that hammer `work`
# while the main thread reloads the object 200x, then asserts the workers survived
# and the patch took effect. Exit code is propagated: 0 = PASS, non-zero = FAIL.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'mt.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue   # start from a clean manifest

Write-Host '==> building mt-test .exe (-hot-reload: bakes the table, hotpatch pad, /OPT:NOICF)'
& $odin build $here -out:(Join-Path $work 'mt_test.exe') -debug -hot-reload -hot-reload-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> simulating an edit: work now adds 100 instead of 1'
$src = Join-Path $work 'src'
Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $src | Out-Null
$edited = (Get-Content -Raw (Join-Path $here 'mt_test.odin')) -replace 's\.n \+= 1\b', 's.n += 100'
if ($edited -notmatch 's\.n \+= 100') { throw 'edit substitution failed (source marker changed?)' }
$edited | Out-File -Encoding utf8 (Join-Path $src 'mt_test.odin')

Write-Host '==> compiling the edit to a multi-object reload set (separate modules, same manifest)'
$objs = Join-Path $work 'objs'
Remove-Item $objs -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $objs | Out-Null
# No -use-single-module: emit one object per package into objs/. The loader (apply_dir)
# maps them all and relocates them against the exe AND against each other.
& $odin build $src -build-mode:obj -hot-reload -hot-reload-manifest:$manifest -out:(Join-Path $objs 'mt_hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running the stress test (workers hammer `work` while the main thread reloads 200x)'
Push-Location $work
try {
	& (Join-Path $work 'mt_test.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) {
	Write-Host '==> RESULT: PASS' -ForegroundColor Green
} else {
	Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red
}
exit $code
