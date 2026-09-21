# ---------------------------------------------------------------------------
# Diff.ps1 - compare two snapshots and show what actually changed.
#
# This is the payoff of snapshotting. Flatten both JSON trees to dotted paths,
# compare values, then split the differences into:
#   SIGNAL - things that should NOT drift during a session. A change here is a
#            candidate root cause: display mode, topology sets, driver state,
#            adapter LUID a process is using, PCIe link, DWM registry.
#   NOISE  - things expected to change every sample: counters, utilisation,
#            memory, uptime, timestamps, handle counts.
#
# Read-only. No admin rights.
# ---------------------------------------------------------------------------

# Paths matching these are always noise.
$script:JLNoisePatterns = @(
    '^Meta\.',
    '^DwmTiming\.',
    '^SystemCounters\.',
    '^GpuAdapterMemory\[',
    '^GpuEngine\[\d+\]\.Util$',
    '^Nvidia\.(clocks\.|utilization\.|memory\.used|temperature|power\.draw|pstate|clocks_event_reasons\.)',
    '\.CpuSec$',
    '\.WorkingSetMB$',
    '\.Handles$',
    '\.Threads$'
)

# Paths matching these are high signal and are reported first, loudly.
$script:JLSignalPatterns = @(
    '^VideoControllers\[\d+\]\.(HorizRes|VertRes|RefreshRate|MinRefresh|MaxRefresh|BitsPerPel|VideoMode|Status|Availability|ConfigMgrErr|DriverVersion)',
    '^DisplayDevices\[',
    '^Monitors\[',
    '^Screens\[',
    '^Registry\.',
    '^Services\[',
    '^NvDisplayContainers\[',
    '^Nvidia\.pcie\.',
    '^DwmCompositionEnabled$',
    '^PowerScheme$',
    '\.Luid$'
)

function ConvertTo-JLFlat {
    # Not Mandatory: snapshot arrays can legitimately contain nulls, and a
    # Mandatory parameter rejects them (found on the first real diff).
    param([AllowNull()] $Object, [string] $Prefix = '')
    $out = [ordered]@{}
    if ($null -eq $Object) { $out[$Prefix] = '<null>'; return $out }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) {
            $p = if ($Prefix) { "$Prefix.$k" } else { "$k" }
            (ConvertTo-JLFlat -Object $Object[$k] -Prefix $p).GetEnumerator() | ForEach-Object { $out[$_.Key] = $_.Value }
        }
    }
    elseif ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Object.PSObject.Properties) {
            $p = if ($Prefix) { "$Prefix.$($prop.Name)" } else { "$($prop.Name)" }
            (ConvertTo-JLFlat -Object $prop.Value -Prefix $p).GetEnumerator() | ForEach-Object { $out[$_.Key] = $_.Value }
        }
    }
    elseif ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        $i = 0
        foreach ($item in $Object) {
            (ConvertTo-JLFlat -Object $item -Prefix "$Prefix[$i]").GetEnumerator() | ForEach-Object { $out[$_.Key] = $_.Value }
            $i++
        }
        if ($i -eq 0) { $out[$Prefix] = '<empty>' }
    }
    else { $out[$Prefix] = "$Object" }
    return $out
}

function Compare-JLSnapshot {
    param(
        [Parameter(Mandatory)] [string] $GoodPath,
        [Parameter(Mandatory)] [string] $BadPath,
        [switch] $IncludeNoise
    )

    foreach ($p in @($GoodPath, $BadPath)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Snapshot not found: $p" }
    }

    $good = ConvertTo-JLFlat (Get-Content -LiteralPath $GoodPath -Raw | ConvertFrom-Json)
    $bad  = ConvertTo-JLFlat (Get-Content -LiteralPath $BadPath  -Raw | ConvertFrom-Json)

    $keys = ($good.Keys + $bad.Keys) | Sort-Object -Unique
    $diffs = foreach ($k in $keys) {
        $g = if ($good.Contains($k)) { $good[$k] } else { '<absent>' }
        $b = if ($bad.Contains($k))  { $bad[$k]  } else { '<absent>' }
        if ($g -ne $b) {
            $isNoise  = $false
            foreach ($pat in $script:JLNoisePatterns)  { if ($k -match $pat) { $isNoise = $true; break } }
            $isSignal = $false
            foreach ($pat in $script:JLSignalPatterns) { if ($k -match $pat) { $isSignal = $true; break } }
            [pscustomobject]@{
                Path  = $k
                Good  = $g
                Bad   = $b
                Class = if ($isSignal) { 'SIGNAL' } elseif ($isNoise) { 'noise' } else { 'other' }
            }
        }
    }

    if (-not $IncludeNoise) { $diffs = $diffs | Where-Object { $_.Class -ne 'noise' } }
    return $diffs | Sort-Object @{ Expression = { switch ($_.Class) { 'SIGNAL' { 0 } 'other' { 1 } default { 2 } } } }, Path
}

function Show-JLDiff {
    param(
        [Parameter(Mandatory)] [string] $GoodPath,
        [Parameter(Mandatory)] [string] $BadPath,
        [switch] $IncludeNoise
    )
    $d = Compare-JLSnapshot -GoodPath $GoodPath -BadPath $BadPath -IncludeNoise:$IncludeNoise
    Write-Host ""
    Write-Host "GOOD: $GoodPath"
    Write-Host "BAD : $BadPath"
    Write-Host ""
    if (-not $d) { Write-Host "No differences outside the known-noisy fields."; return }

    foreach ($grp in ($d | Group-Object Class)) {
        Write-Host "=== $($grp.Name) ($($grp.Count)) ==="
        foreach ($row in $grp.Group) {
            Write-Host ("  {0}" -f $row.Path)
            Write-Host ("      good: {0}" -f $row.Good)
            Write-Host ("      bad : {0}" -f $row.Bad)
        }
        Write-Host ""
    }
    Write-Host "SIGNAL rows are things that should not drift during a session - start there."
}
