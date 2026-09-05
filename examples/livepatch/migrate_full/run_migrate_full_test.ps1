# Comprehensive migration test: add + rename + reorder + remove + enum-remap in ONE reload.
#
#   powershell -ExecutionPolicy Bypass -File examples\livepatch\migrate_full\run_migrate_full_test.ps1
#
# The exe is built from {app.odin, serializer.odin, v1/state.odin}; the reload object
# from {app.odin, serializer.odin, v2/state.odin}. The exe sets known values, reloads,
# and the pre/post hooks migrate every surviving field BY NAME (health->hp alias, a
# reordered scores array, an enum whose constants were re-ordered) while zeroing the new
# field and dropping the removed one. Exit 0 = PASS.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$env:ODIN_ROOT = $repo
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'migrate_full.manifest'

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

Write-Host '==> building migrate-full .exe (v1 layout)'
$exeSrc = Stage 'exe_src' 'v1'
& $odin build $exeSrc -out:(Join-Path $work 'migrate_full.exe') -debug -livepatch -livepatch-manifest:$manifest -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> compiling v2 layout to migrate_full_hot.obj (same manifest)'
$objSrc = Stage 'obj_src' 'v2'
& $odin build $objSrc -build-mode:obj -use-single-module -livepatch -livepatch-manifest:$manifest -out:(Join-Path $work 'migrate_full_hot.obj') -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running'
Push-Location $work
try {
	& (Join-Path $work 'migrate_full.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green }
else             { Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red }
exit $code
