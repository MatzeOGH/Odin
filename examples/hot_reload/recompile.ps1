# Recompile the CURRENT game.odin to hot.obj, against the manifest run.ps1 produced.
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\recompile.ps1
#
# Do NOT rebuild the exe (that restarts the process). This rebuilds only the object;
# the same manifest gives any NEW global a stable arena slot across reloads. After it
# succeeds, switch back to the running exe and press `r` to patch it in place.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$odin = Join-Path $here '..\..\odin.exe'

Set-Location $here
if (-not (Test-Path (Join-Path $here 'odin-hot-reload.manifest'))) {
	throw 'odin-hot-reload.manifest not found — run run.ps1 first (it builds the exe and the manifest).'
}

Write-Host '==> recompiling game.odin -> hot_objs\ (separate modules)'
$objs = Join-Path $here 'hot_objs'
Remove-Item $objs -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $objs | Out-Null
# No -use-single-module: emit one object per package. The standard library is resolved from
# the running exe (its objects are not emitted), and an unchanged user package is not
# re-emitted at all — so a reload typically produces just the default/metadata object plus the
# package(s) you actually edited. The loader (apply_dir) maps the whole set together.
& $odin build . -build-mode:obj -hot-reload -out:(Join-Path $objs 'hot.obj')
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> hot_objs\ ready — press `r` in the running exe to reload.'
