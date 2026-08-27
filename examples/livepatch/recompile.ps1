# Recompile the CURRENT game.odin to the reload patch, against the manifest run.ps1 produced.
#
#   powershell -ExecutionPolicy Bypass -File examples\livepatch\recompile.ps1
#
# Do NOT rebuild the exe (that restarts the process). `-livepatch-patch` builds only the
# reload object(s): it implies -build-mode:obj, emits into .\hot_objs\ (creating it and
# clearing any stale *.obj first), and reuses the default manifest so any NEW global gets a
# stable arena slot across reloads. After it succeeds, switch back to the running exe and
# press `r` to patch it in place.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$odin = Join-Path $here '..\..\odin.exe'

Set-Location $here

Write-Host '==> recompiling game.odin -> hot_objs\ (odin build . -livepatch-patch)'
& $odin build . -livepatch-patch
if ($LASTEXITCODE -ne 0) { throw 'patch build failed' }

Write-Host '==> hot_objs\ ready — press `r` in the running exe to reload.'
