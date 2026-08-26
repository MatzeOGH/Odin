# Build the demo .exe with hot-reload enabled, then run it (leave this running).
#
#   powershell -ExecutionPolicy Bypass -File examples\hot_reload\run.ps1
#
# `-hot-reload` bakes the symbol table + reserves the new-global arena; the manifest
# records the layout so later `hot.obj` builds line up against it. The manifest is
# reset here so every fresh run starts from a clean layout. The exe loads `hot.obj`
# from its working directory, so we build + run from this folder.
#
# While it runs:  [enter]/t = tick    r = reload from hot.obj    q = quit
# Edit game.odin, run recompile.ps1 (Zed: ctrl-alt-r), then press `r` here.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$odin = Join-Path $here '..\..\odin.exe'

Set-Location $here
Remove-Item (Join-Path $here 'hot.manifest') -ErrorAction SilentlyContinue

Write-Host '==> building hot_reload.exe (-hot-reload)'
& $odin build . -out:hot_reload.exe -debug -hot-reload -hot-reload-manifest:hot.manifest -extra-linker-flags:"/OPT:NOREF,NOICF"
if ($LASTEXITCODE -ne 0) { throw 'exe build failed' }

Write-Host '==> running (leave this terminal open; edit + recompile, then press r)'
& (Join-Path $here 'hot_reload.exe')
