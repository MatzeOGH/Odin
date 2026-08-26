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
if (-not (Test-Path (Join-Path $here 'hot.manifest'))) {
	throw 'hot.manifest not found — run run.ps1 first (it builds the exe and the manifest).'
}

Write-Host '==> recompiling game.odin -> hot.obj'
& $odin build . -build-mode:obj -use-single-module -hot-reload -hot-reload-manifest:hot.manifest -out:hot.obj
if ($LASTEXITCODE -ne 0) { throw 'obj build failed' }

Write-Host '==> hot.obj ready — press `r` in the running exe to reload.'
