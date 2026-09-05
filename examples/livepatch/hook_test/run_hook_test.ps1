# Automated test for autowired pre/post-patch hooks (Windows / x64).
#
#   powershell -ExecutionPolicy Bypass -File examples\livepatch\hook_test\run_hook_test.ps1
#
# Builds the test .exe (-livepatch, VER=1), simulates an edit (VER 1->2 and
# `work` adds 100 instead of 1), compiles that to hook_hot.obj, and runs the .exe.
# The .exe reloads the object once and asserts the pre hook ran old (exe) code
# (VER=1) and the post hook ran new (obj) code (VER=2). Exit 0 = PASS.

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$repo     = Resolve-Path (Join-Path $here '..\..\..')
$odin     = Join-Path $repo 'odin.exe'
$env:ODIN_ROOT = $repo   # use THIS repo's core (with the livepatch changes), not a global ODIN_ROOT
$work     = Join-Path $here '.work'
$manifest = Join-Path $work 'hook.manifest'

New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item $manifest -ErrorAction SilentlyContinue

Write-Host '==> building hook-test .exe (-livepatch, VER=1)'
& $odin build $here -out:(Join-Path $work 'hook_test.exe') -debug -livepatch -livepatch-manifest:$manifest -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> simulating an edit: VER 1->2, work adds 100'
$src = Join-Path $work 'src'
Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $src | Out-Null
$edited = (Get-Content -Raw (Join-Path $here 'hook_test.odin'))
$edited = $edited -replace 'VER :: 1', 'VER :: 2'
$edited = $edited -replace 's\.n \+= 1\b', 's.n += 100'
$edited = $edited -replace '// LP_EXTRA_FIELD.*', 'extra: i64,'
$edited = $edited -replace 'Mode :: enum \{ Idle, Run, Stop \}', 'Mode :: enum { Stop, Idle, Run }'
$edited = $edited -replace 'Shape  :: union \{ Circle, Square \}', 'Shape  :: union { Square, Circle }'
if ($edited -notmatch 'VER :: 2')   { throw 'edit substitution failed (VER marker changed?)' }
if ($edited -notmatch 's\.n \+= 100') { throw 'edit substitution failed (work marker changed?)' }
if ($edited -notmatch 'extra: i64,') { throw 'edit substitution failed (State field marker changed?)' }
if ($edited -notmatch 'Mode :: enum \{ Stop, Idle, Run \}') { throw 'edit substitution failed (Mode enum marker changed?)' }
if ($edited -notmatch 'Shape  :: union \{ Square, Circle \}') { throw 'edit substitution failed (Shape union marker changed?)' }
$edited | Out-File -Encoding utf8 (Join-Path $src 'hook_test.odin')

Write-Host '==> compiling the edit to hook_hot.obj (same manifest)'
& $odin build $src -build-mode:obj -use-single-module -livepatch -livepatch-manifest:$manifest -out:(Join-Path $work 'hook_hot.obj') -ignore-unknown-attributes
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> running'
Push-Location $work
try {
	& (Join-Path $work 'hook_test.exe')
	$code = $LASTEXITCODE
}
finally { Pop-Location }

if ($code -eq 0) { Write-Host '==> RESULT: PASS' -ForegroundColor Green }
else             { Write-Host "==> RESULT: FAIL (exit $code)" -ForegroundColor Red }
exit $code
