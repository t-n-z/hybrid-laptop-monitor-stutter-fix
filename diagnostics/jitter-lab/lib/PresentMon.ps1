# ---------------------------------------------------------------------------
# PresentMon.ps1 - wrapper around Intel PresentMon. NEEDS ELEVATION.
#
# WHY IT MATTERS HERE: PresentMon reports, per window, which presentation mode
# the surface is in - "Composed: Flip" versus "Hardware Composed: Independent
# Flip" - plus frame times and display latency. The leading external theory for
# this class of judder is DWM oscillating swap chains between those two modes
# based on perceived frame rate. PresentMon is the instrument that confirms or
# kills that theory outright.
#
# It also has --track_hybrid_present, which flags presents that are copied
# across adapters. On a hybrid laptop that is exactly the cross-adapter path
# hypothesis 1 is about.
#
# Binary lives in bin\PresentMon.exe (staged, not run). Intel, open source.
# ---------------------------------------------------------------------------

function Get-JLPresentMonPath {
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string]    $KitRoot
    )
    $p = Join-Path $KitRoot $Config.PresentMonExe
    if (Test-Path -LiteralPath $p) { return $p }
    # tolerate the versioned file name the Intel release ships with
    $alt = Get-ChildItem -LiteralPath (Join-Path $KitRoot 'bin') -Filter 'PresentMon*.exe' -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
    if ($alt) { return $alt.FullName }
    return $null
}

function Invoke-JLPresentMon {
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string]    $KitRoot,
        [Parameter(Mandatory)] [string]    $DataDir,
        [ValidateSet('jitter', 'good', 'manual')] [string] $Label = 'manual',
        [int]    $Seconds = 0,
        [string] $ProcessName                      # optional: limit to one process
    )
    if ($Seconds -le 0) { $Seconds = $Config.PresentMonSeconds }

    $exe = Get-JLPresentMonPath -Config $Config -KitRoot $KitRoot
    if (-not $exe) { throw "PresentMon not found. Expected $($Config.PresentMonExe) under the kit root. See docs\ELEVATED-STEPS.md." }
    if (-not (Test-JLElevated)) { throw 'PresentMon needs an elevated PowerShell to trace other processes.' }

    $dir = Join-Path $DataDir 'presentmon'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $csv = Join-Path $dir ('pm-{0}-{1}.csv' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $Label)

    # --terminate_after_timed keeps it bounded; --stop_existing_session avoids
    # a stale ETW session blocking the run.
    # Flags verified against PresentMon 2.5.1 --help on 2026-09-21. '--no_top'
    # was a 1.x flag and makes 2.x exit 1. --track_hybrid_present flags
    # presents copied across adapters: the hybrid-laptop question directly.
    $pmArgs = @('--output_file', "`"$csv`"", '--timed', "$Seconds", '--terminate_after_timed',
              '--stop_existing_session', '--no_console_stats', '--track_hybrid_present')
    if ($ProcessName) { $pmArgs += @('--process_name', $ProcessName) }

    Write-Host "PresentMon capturing $Seconds s -> $csv"
    Write-Host "  -> Drag a window around and scroll while this runs."
    $p = Start-Process -FilePath $exe -ArgumentList $pmArgs -WindowStyle Hidden -PassThru -Wait
    if ($p.ExitCode -ne 0) { Write-Warning "PresentMon exited with code $($p.ExitCode). Some builds use different flag names - run '$exe --help' to check." }

    if (Test-Path -LiteralPath $csv) {
        return [pscustomobject]@{ Path = $csv; SizeMB = [math]::Round((Get-Item -LiteralPath $csv).Length / 1MB, 2) }
    }
    throw "PresentMon produced no output at $csv."
}

function Get-JLPresentModeSummary {
    <#  Boil a PresentMon CSV down to the one question we care about: which
        presentation modes were in use, by which process, and how often.
        Run this on the jitter capture and the good capture, then compare.  #>
    param([Parameter(Mandatory)] [string] $CsvPath)

    if (-not (Test-Path -LiteralPath $CsvPath)) { throw "Not found: $CsvPath" }
    $rows = Import-Csv -LiteralPath $CsvPath
    if (-not $rows) { return @() }

    # Column names vary between PresentMon versions; find them rather than assume.
    $cols    = $rows[0].PSObject.Properties.Name
    $modeCol = $cols | Where-Object { $_ -match 'PresentMode' }           | Select-Object -First 1
    $procCol = $cols | Where-Object { $_ -match 'Application|ProcessName' } | Select-Object -First 1
    if (-not $modeCol) { throw "No PresentMode column found in $CsvPath. Columns: $($cols -join ', ')" }

    $rows | Group-Object -Property $procCol, $modeCol | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{
            Process     = $_.Group[0].$procCol
            PresentMode = $_.Group[0].$modeCol
            Frames      = $_.Count
        }
    }
}
