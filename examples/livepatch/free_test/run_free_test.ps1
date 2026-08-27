# Regression test for deferred free of previously mapped reload blocks (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\livepatch\free_test\run_free_test.ps1
#
# Builds the host (-livepatch), then builds TWO distinct reload objects (work += 100 and
# work += 101) into objsA/ and objsB/. The host alternates reloading them 200x while worker
# threads hammer `work`, then asserts the workers survived and the live reload-generation
# count stayed bounded (old blocks were freed, not leaked). Exit 0 = PASS.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'free.manifest'

$env:ODIN_ROOT = $repo

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue

Write-Host '==> building free-test host (-livepatch)'
& $odin build $here -out:(Join-Path $work 'free_test.exe') -debug -livepatch -livepatch-manifest:$manifest
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

function Build-Variant($add, $dir) {
	$src = Join-Path $work "src_$add"
	Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Force $src | Out-Null
	$edited = (Get-Content -Raw (Join-Path $here 'free_test.odin')) -replace 's\.n \+= 1\b', "s.n += $add"
	if ($edited -notmatch "s\.n \+= $add") { throw "edit substitution failed for $add" }
	$edited | Out-File -Encoding utf8 (Join-Path $src 'free_test.odin')
	$objs = Join-Path $work $dir
	Remove-Item $objs -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Force $objs | Out-Null
	& $odin build $src -build-mode:obj -livepatch -livepatch-manifest:$manifest -out:(Join-Path $objs 'free_hot.obj')
	if ($LASTEXITCODE -ne 0) { throw "obj build failed for $add" }
}

Write-Host '==> building two distinct reload variants (objsA: +100, objsB: +101)'
Build-Variant 100 'objsA'
Build-Variant 101 'objsB'

Write-Host '==> running (alternate objsA/objsB 200x while workers hammer work)'
Push-Location $work
try {
	& (Join-Path $work 'free_test.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) {
	Write-Host '==> RESULT: PASS' -ForegroundColor Green
} else {
	Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red
}
exit $code
