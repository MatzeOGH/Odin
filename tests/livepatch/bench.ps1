# Measures what -livepatch preloading costs: -livepatch-no-preload is the A/B switch, so there is
# nothing to stash or rebuild between runs.
#
# Timing these builds naively is misleading -- they are under a second, so a cold first run swamps
# the difference. Hence: a discarded warmup, three runs per configuration with the order alternated
# so drift hits both modes equally, and the minimum reported.
#
#   powershell -File tests/livepatch/bench.ps1

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..')
$odin = Join-Path $root 'odin.exe'
$work = Join-Path $root 'tests\livepatch\bench'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }

# One package per mode so manifests/hot_objs don't cross-contaminate.
$pkgs = @{}
foreach ($mode in 'preload','lean') {
    $p = Join-Path $work $mode
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Copy-Item (Join-Path $root 'examples\livepatch_demo\*.odin') $p -Force
    Copy-Item (Join-Path $root 'examples\livepatch_demo\image_v1.png') $p -Force
    Copy-Item (Join-Path $root 'examples\livepatch_demo\image_v2.png') $p -Force
    $pkgs[$mode] = $p
}

function Run($mode, $kind) {
    $p = $pkgs[$mode]
    $extra = if ($mode -eq 'lean') { @('-livepatch-no-preload') } else { @() }
    if ($kind -eq 'base') {
        $a = @('build', $p, '-livepatch', '-debug', "-out:$p\b.exe") + $extra
    } else {
        $a = @('build', $p, '-livepatch-patch')
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $odin @a | Out-Null
    $sw.Stop()
    if ($LASTEXITCODE -ne 0) { throw "$mode $kind failed" }
    return $sw.Elapsed.TotalSeconds
}

# Warm the filesystem/compiler caches first; discard.
Run 'preload' 'base' | Out-Null
Run 'lean'    'base' | Out-Null

$res = @{}
foreach ($kind in 'base','patch') {
    foreach ($mode in 'preload','lean') { $res["$mode-$kind"] = @() }
    # Alternate order across iterations so drift hits both modes equally.
    for ($i = 0; $i -lt 3; $i++) {
        $order = if ($i % 2 -eq 0) { @('preload','lean') } else { @('lean','preload') }
        foreach ($mode in $order) { $res["$mode-$kind"] += (Run $mode $kind) }
    }
}

Write-Host ''
Write-Host 'examples/livepatch_demo -- 3 runs each, alternating order'
Write-Host ''
foreach ($kind in 'base','patch') {
    foreach ($mode in 'preload','lean') {
        $v = $res["$mode-$kind"] | Sort-Object
        Write-Host ("  {0,-6} {1,-8} min={2,5:N2}s  med={3,5:N2}s  all={4}" -f $kind, $mode, $v[0], $v[1], (($v | ForEach-Object { '{0:N2}' -f $_ }) -join ' '))
    }
    $pm = ($res["preload-$kind"] | Measure-Object -Minimum).Minimum
    $lm = ($res["lean-$kind"]    | Measure-Object -Minimum).Minimum
    Write-Host ("  -> {0}: preload/lean = {1:N2}x  (+{2:N2}s)" -f $kind, ($pm/$lm), ($pm-$lm))
    Write-Host ''
}
foreach ($mode in 'preload','lean') {
    $e = Join-Path $pkgs[$mode] 'b.exe'
    $d = Join-Path $pkgs[$mode] 'b.pdb'
    Write-Host ("  {0,-8} exe={1,6:N2}MB pdb={2,6:N2}MB" -f $mode, ((Get-Item $e).Length/1MB), ((Get-Item $d).Length/1MB))
}
