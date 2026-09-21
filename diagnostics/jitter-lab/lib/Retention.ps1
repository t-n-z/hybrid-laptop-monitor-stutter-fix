# ---------------------------------------------------------------------------
# Retention.ps1 - the disk-budget janitor. Keeps DataDir under MaxDataMB.
#
# Rules, in order:
#   1. Nothing inside DataDir\keep\ is ever touched. Pin anything valuable
#      there (a matched good/jitter pair, the trace that cracks it).
#   2. Trim by count first: oldest ETL traces, then rotated CSVs, then
#      snapshots, down to the per-type caps in config.psd1.
#   3. If still over budget, delete oldest unpinned files until under it.
#   4. ETL traces go first at every stage: they are 10-100x the size of
#      everything else, so they dominate the budget.
#
# Read-only outside DataDir. No admin rights.
# ---------------------------------------------------------------------------

function Get-JLDataUsageMB {
    param([Parameter(Mandatory)] [string] $DataDir)
    if (-not (Test-Path -LiteralPath $DataDir)) { return 0 }
    $bytes = (Get-ChildItem -LiteralPath $DataDir -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    return [math]::Round(($bytes / 1MB), 2)
}

function Invoke-JLRetention {
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string]    $DataDir,
        [switch] $WhatIfOnly
    )

    $result = [ordered]@{
        StartMB = Get-JLDataUsageMB -DataDir $DataDir
        Deleted = @()
        EndMB   = $null
        Warning = $null
    }
    if (-not (Test-Path -LiteralPath $DataDir)) { $result.EndMB = 0; return [pscustomobject]$result }

    $keep = Join-Path $DataDir 'keep'
    $isPinned = {
        param($file)
        $file.FullName.StartsWith($keep, [StringComparison]::OrdinalIgnoreCase)
    }

    $del = New-Object System.Collections.Generic.List[object]

    function Get-Unpinned {
        param([string] $Filter, [string] $SubDir)
        $root = if ($SubDir) { Join-Path $DataDir $SubDir } else { $DataDir }
        if (-not (Test-Path -LiteralPath $root)) { return @() }
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
            Where-Object { -not (& $isPinned $_) } | Sort-Object LastWriteTime
    }

    # --- 2. trim by count, biggest-first by type ---------------------------
    $traces = @(Get-Unpinned -Filter '*.etl' -SubDir 'traces')
    if ($traces.Count -gt $Config.MaxTraceCount) {
        $traces | Select-Object -First ($traces.Count - $Config.MaxTraceCount) | ForEach-Object { $del.Add($_) }
    }

    # rotated CSVs carry a -HHmmss suffix; the live ones do not, so this never
    # deletes the file the sampler is currently writing to.
    foreach ($stream in 'dwm', 'sys', 'nvidia', 'display') {
        $rot = @(Get-Unpinned -Filter "$stream-*-*.csv" -SubDir 'live')
        if ($rot.Count -gt $Config.KeepRotatedCsv) {
            $rot | Select-Object -First ($rot.Count - $Config.KeepRotatedCsv) | ForEach-Object { $del.Add($_) }
        }
    }

    $snaps = @(Get-Unpinned -Filter 'snap-*.json' -SubDir 'snapshots')
    if ($snaps.Count -gt $Config.KeepSnapshots) {
        $snaps | Select-Object -First ($snaps.Count - $Config.KeepSnapshots) | ForEach-Object { $del.Add($_) }
    }

    if (-not $WhatIfOnly) {
        foreach ($f in $del) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $result.Deleted += $f.FullName } catch { } }
    } else {
        $result.Deleted += ($del | ForEach-Object { $_.FullName })
    }

    # --- 3. still over budget: oldest unpinned, traces first ---------------
    $used = Get-JLDataUsageMB -DataDir $DataDir
    if ($used -gt $Config.MaxDataMB) {
        $candidates = @(
            @(Get-Unpinned -Filter '*.etl' -SubDir 'traces')
            @(Get-ChildItem -LiteralPath $DataDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { -not (& $isPinned $_) -and $_.Extension -ne '.etl' -and $_.Name -ne 'STOP' } |
                Sort-Object LastWriteTime)
        )
        foreach ($f in $candidates) {
            if ((Get-JLDataUsageMB -DataDir $DataDir) -le $Config.MaxDataMB) { break }
            if ($WhatIfOnly) { $result.Deleted += $f.FullName; continue }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $result.Deleted += $f.FullName } catch { }
        }
    }

    $result.EndMB = Get-JLDataUsageMB -DataDir $DataDir
    if ($result.EndMB -gt ($Config.MaxDataMB * $Config.WarnAtFraction)) {
        $result.Warning = "DataDir at $($result.EndMB) MB of $($Config.MaxDataMB) MB budget."
    }
    # A pinned folder larger than the whole budget can never be trimmed away.
    # Say so plainly rather than silently failing to hold the limit.
    if ($result.EndMB -gt $Config.MaxDataMB) {
        $pinnedMB = if (Test-Path -LiteralPath $keep) { [math]::Round(((Get-ChildItem -LiteralPath $keep -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 2) } else { 0 }
        $result.Warning = "OVER BUDGET: $($result.EndMB) MB of $($Config.MaxDataMB) MB, of which $pinnedMB MB is pinned in keep\ and cannot be auto-deleted."
    }
    return [pscustomobject]$result
}
