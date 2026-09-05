# Multi-reload regression test: the loader's TYPE baseline must advance every reload, so
# Type_Change.old reflects the LAST reload, not app start.
#
#   powershell -ExecutionPolicy Bypass -File examples\livepatch\migrate_twice\run_migrate_twice_test.ps1
#
# The exe is built from {app.odin, serializer.odin, v1/state.odin}; reload object 1 from the
# v2 layout, reload object 2 from the v3 layout — all against the same manifest. The exe sets
# known values, reloads twice, and asserts the second reload diffed against the v2 (current-
# live) layout rather than the v1 (app-start) one. Exit 0 = PASS.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$env:ODIN_ROOT = $repo
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'migrate_twice.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue

# Stage a build dir combining the shared files with one version's state.odin.
function Stage($name, $stateDir) {
	$d = Join-Path $work $name
	Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Force $d | Out-Null
	Copy-Item (Join-Path $here 'app.odin')        $d
	Copy-Item (Join-Path $here 'serializer.odin') $d
	Copy-Item (Join-Path $here "$stateDir\state.odin") $d
	return $d
}

Write-Host '==> building migrate-twice .exe (v1 layout)'
$exeSrc = Stage 'exe_src' 'v1'
& $odin build $exeSrc -out:(Join-Path $work 'migrate_twice.exe') -debug -livepatch -livepatch-manifest:$manifest -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> compiling reload 1 (v2 layout) to mt1_hot.obj (same manifest)'
$obj1Src = Stage 'obj1_src' 'v2'
& $odin build $obj1Src -build-mode:obj -use-single-module -livepatch -livepatch-manifest:$manifest -out:(Join-Path $work 'mt1_hot.obj') -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'obj 1 build failed' }

Write-Host '==> compiling reload 2 (v3 layout) to mt2_hot.obj (same manifest)'
$obj2Src = Stage 'obj2_src' 'v3'
& $odin build $obj2Src -build-mode:obj -use-single-module -livepatch -livepatch-manifest:$manifest -out:(Join-Path $work 'mt2_hot.obj') -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'obj 2 build failed' }

Write-Host '==> running'
Push-Location $work
try {
	& (Join-Path $work 'migrate_twice.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green }
else             { Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red }
exit $code
