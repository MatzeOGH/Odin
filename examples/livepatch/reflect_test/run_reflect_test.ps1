# Automated test: reflection (type_info) refresh across a livepatch.
#
#   powershell -ExecutionPolicy Bypass -File examples\livepatch\reflect_test\run_reflect_test.ps1
#
# Builds the .exe (-livepatch, Thing v1: one field, no Extra), simulates an edit that adds
# `y: i64` to Thing and introduces a brand-new `Extra` type + a check over it, compiles that to
# reflect_hot.obj, and runs the .exe. The patched `check` reflects the NEW-layout values via
# `fmt`; the run passes iff the new field and new type are visible after the reload. Exit 0 = PASS.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$env:ODIN_ROOT = $repo
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'reflect.manifest'
$objdir   = Join-Path $here 'hot_objs'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue
Remove-Item (Join-Path $objdir '*.obj') -ErrorAction SilentlyContinue

Write-Host '==> building reflect-test .exe (-livepatch, Thing v1)'
& $odin build $here -out:(Join-Path $work 'reflect_test.exe') -livepatch -livepatch-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> simulating an edit: add `y: i64` to Thing, add a brand-new `Extra` type'
$src = Join-Path $work 'src'
Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $src | Out-Null
$edited = (Get-Content -Raw (Join-Path $here 'reflect_test.odin'))
$edited = $edited -replace '// LP_NEW_FIELD', 'y: i64,'
$edited = $edited -replace '// LP_NEW_TYPE', 'Extra :: struct { p: int, q: string }'
$edited = $edited -replace '// LP_CHECK_NEW', 'ex := fmt.aprint(Extra{p = 5, q = "hi"}); defer delete(ex); g_pass = strings.contains(th, "y =") && strings.contains(ex, "p =") && strings.contains(ex, "q =")'
if ($edited -notmatch 'y: i64,')            { throw 'edit substitution failed (Thing field marker changed?)' }
if ($edited -notmatch 'Extra :: struct')    { throw 'edit substitution failed (new-type marker changed?)' }
$edited | Out-File -Encoding utf8 (Join-Path $src 'reflect_test.odin')

Write-Host '==> compiling the edit to hot_objs\reflect_hot.obj (same manifest)'
New-Item -ItemType Directory -Force $objdir | Out-Null
& $odin build $src -build-mode:obj -use-single-module -livepatch -livepatch-manifest:$manifest -out:(Join-Path $objdir 'reflect_hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running'
Push-Location $here
try {
	& (Join-Path $work 'reflect_test.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green }
else             { Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red }
exit $code
