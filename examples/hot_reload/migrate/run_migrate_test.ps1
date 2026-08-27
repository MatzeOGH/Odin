# Automated test: reflection-based state migration across a struct layout change.
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\migrate\run_migrate_test.ps1
#
# Builds the .exe (-hot-reload, State v1), simulates an edit that inserts a new field
# `extra` at the FRONT of State (shifting every following field's offset) and bumps
# EDIT_VERSION, compiles that to migrate_hot.obj, and runs the .exe. The .exe sets
# State to known values, reloads, and asserts the pre/post hooks migrated every
# surviving field BY NAME to its new offset (and zeroed the new field). Exit 0 = PASS.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$env:ODIN_ROOT = $repo
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'migrate.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue

Write-Host '==> building migrate-test .exe (-hot-reload, State v1)'
& $odin build $here -out:(Join-Path $work 'migrate_test.exe') -debug -hot-reload -hot-reload-manifest:$manifest -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> simulating an edit: insert `extra: i64` at the FRONT of State, EDIT_VERSION 1->2'
$src = Join-Path $work 'src'
Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $src | Out-Null
Copy-Item (Join-Path $here 'serializer.odin') (Join-Path $src 'serializer.odin')
$edited = (Get-Content -Raw (Join-Path $here 'migrate.odin'))
$edited = $edited -replace 'EDIT_VERSION :: 1', 'EDIT_VERSION :: 2'
$edited = $edited -replace '// HR_EXTRA_FIELD.*', 'extra: i64,'
if ($edited -notmatch 'EDIT_VERSION :: 2') { throw 'edit substitution failed (EDIT_VERSION marker changed?)' }
if ($edited -notmatch 'extra: i64,')       { throw 'edit substitution failed (State field marker changed?)' }
$edited | Out-File -Encoding utf8 (Join-Path $src 'migrate.odin')

Write-Host '==> compiling the edit to migrate_hot.obj (same manifest)'
& $odin build $src -build-mode:obj -use-single-module -hot-reload -hot-reload-manifest:$manifest -out:(Join-Path $work 'migrate_hot.obj') -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running'
Push-Location $work
try {
	& (Join-Path $work 'migrate_test.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green }
else             { Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red }
exit $code
