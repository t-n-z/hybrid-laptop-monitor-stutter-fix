<#
.SYNOPSIS
    JitterLab - instrumentation kit for the hybrid-laptop docked-display stutter.

.DESCRIPTION
    Single entry point for every watcher. Nothing here changes machine state:
    the kit only reads counters, registry and WMI, and writes to its own
    DataDir. The one exception is ETW tracing and PresentMon, which need an
    elevated shell (Windows requirement, not a choice made here).

    Commands that need NO elevation:
        status  snapshot  start  stop  diff  clean  pack  selftest
    Commands that DO need elevation:
        trace  presentmon  (see docs\ELEVATED-STEPS.md)

.EXAMPLE
    .\JitterLab.ps1 status
.EXAMPLE
    .\JitterLab.ps1 start            # begin continuous sampling
.EXAMPLE
    .\JitterLab.ps1 snapshot jitter  # capture state while it is juddering
.EXAMPLE
    .\JitterLab.ps1 diff             # latest good vs latest jitter
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'snapshot', 'start', 'stop', 'diff', 'trace', 'presentmon',
                 'clean', 'pack', 'selftest', 'help', '_sampler')]
    [string] $Command = 'help',

    [Parameter(Position = 1)]
    [string] $Arg,

    [string] $Good,
    [string] $Bad,
    [int]    $Seconds = 0,
    [int]    $MaxMinutes = 0,
    [switch] $IncludeNoise,
    [switch] $WhatIfOnly,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Version = '1.1.0'

# --- load libraries --------------------------------------------------------
foreach ($lib in 'DwmTiming', 'Snapshot', 'Sampler', 'Retention', 'Diff', 'Trace', 'PresentMon') {
    . (Join-Path $KitRoot "lib\$lib.ps1")
}

# --- config ----------------------------------------------------------------
$CfgPath = Join-Path $KitRoot 'config.psd1'
if (-not (Test-Path -LiteralPath $CfgPath)) { throw "Missing config: $CfgPath" }
$Config  = Import-PowerShellDataFile -LiteralPath $CfgPath
$DataDir = $Config.DataDir

# --- guardrail: never write captured data into a synced folder -------------
# Traces and CSVs are large and would be uploaded continuously. This is also
# why DataDir must never be a synced folder, wherever the kit itself lives.
$SyncedPattern = 'synology ?drive|onedrive|dropbox|google ?drive|[\\/]my drive([\\/]|$)|icloud'
function Assert-JLDataDirSane {
    if ($DataDir -match $SyncedPattern) {
        throw "DataDir '$DataDir' looks like a synced folder. Captures are large and would sync continuously. Point DataDir at a local path such as C:\JitterLab in config.psd1."
    }
    if (-not (Test-Path -LiteralPath $DataDir)) {
        if (-not $Force -and $Command -in @('status', 'diff', 'selftest', 'clean')) { return }
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        Write-Host "Created data directory: $DataDir"
    }
}

function Get-JLLatestSnapshot {
    param([string] $Label)
    $dir = Join-Path $DataDir 'snapshots'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $pattern = if ($Label) { "snap-*-$Label.json" } else { 'snap-*.json' }
    Get-ChildItem -LiteralPath $dir -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-JLSamplerProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '_sampler' }
}

# ===========================================================================
switch ($Command) {

    'help' {
        Get-Help $MyInvocation.MyCommand.Path -Detailed
    }

    'status' {
        Assert-JLDataDirSane
        Write-Host ""
        Write-Host "JitterLab $Version"
        Write-Host "  kit      : $KitRoot"
        Write-Host "  data dir : $DataDir  $(if (Test-Path -LiteralPath $DataDir) { '' } else { '(not created yet)' })"
        $used = Get-JLDataUsageMB -DataDir $DataDir
        Write-Host "  disk     : $used MB used of $($Config.MaxDataMB) MB budget"
        Write-Host "  elevated : $(Test-JLElevated)"

        $s = Get-JLSamplerProcess
        Write-Host "  sampler  : $(if ($s) { "RUNNING (pid $($s.ProcessId))" } else { 'stopped' })"

        $t = Get-JLTraceStatus
        Write-Host "  wpr      : $(if ($t.Running) { 'RECORDING' } else { 'idle' })"

        $pm = Get-JLPresentMonPath -Config $Config -KitRoot $KitRoot
        Write-Host "  presentmon: $(if ($pm) { $pm } else { 'not staged' })"

        Write-Host ""
        Write-Host "  DWM composition right now:"
        try {
            $d = Get-DwmTiming
            Write-Host ("    refresh {0} Hz | compose {1} Hz | dropped {2} | missed {3} | late {4}" -f $d.RefreshHz, $d.ComposeHz, $d.CFramesDropped, $d.CFramesMissed, $d.CFramesLate)
            Write-Host "    (these are lifetime totals; the sampler records per-second deltas)"
        } catch { Write-Host "    unavailable: $($_.Exception.Message)" }

        foreach ($lbl in 'good', 'jitter', 'auto') {
            $n = Get-JLLatestSnapshot -Label $lbl
            Write-Host ("  latest {0,-7}: {1}" -f $lbl, $(if ($n) { $n.Name } else { 'none' }))
        }
        Write-Host ""
    }

    'snapshot' {
        Assert-JLDataDirSane
        $label = if ($Arg) { $Arg } else { 'auto' }
        if ($label -notin @('auto', 'good', 'jitter')) { throw "Label must be auto, good or jitter (got '$label')." }
        $p = Save-JLSnapshot -Dir (Join-Path $DataDir 'snapshots') -Label $label -IncludeNvidiaFull
        Write-Host "Snapshot written: $p"
        if ($label -eq 'jitter') {
            Write-Host ""
            Write-Host "Next, while it is still juddering:"
            Write-Host "  .\JitterLab.ps1 trace jitter        (elevated)"
            Write-Host "  .\JitterLab.ps1 presentmon jitter   (elevated)"
            Write-Host "Then fix it with Ctrl+Alt+D and capture the matching healthy pair:"
            Write-Host "  .\JitterLab.ps1 snapshot good"
        }
    }

    'start' {
        Assert-JLDataDirSane
        if (Get-JLSamplerProcess) { Write-Host "Sampler already running."; break }
        $self = $MyInvocation.MyCommand.Path
        # PS 5.1 Start-Process does NOT quote array items that contain spaces,
        # and kit paths often contain spaces. Quote explicitly.
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$self`"", '_sampler')
        if ($MaxMinutes -gt 0) { $a += @('-MaxMinutes', "$MaxMinutes") }
        Start-Process powershell -ArgumentList $a -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 2
        $s = Get-JLSamplerProcess
        Write-Host $(if ($s) { "Sampler started (pid $($s.ProcessId)). Data: $DataDir" } else { "Sampler did not start - check $DataDir\sampler.log" })
    }

    '_sampler' {
        # internal: the background loop itself
        Assert-JLDataDirSane
        Start-JLSampler -Config $Config -DataDir $DataDir -MaxMinutes $MaxMinutes
    }

    'stop' {
        if (-not (Test-Path -LiteralPath $DataDir)) { Write-Host "Nothing to stop."; break }
        New-Item -ItemType File -Path (Join-Path $DataDir 'STOP') -Force | Out-Null
        Write-Host "Stop requested. Waiting for the sampler to finish its current pass..."
        # A pass can include a GPU-engine counter read or a full snapshot, both
        # of which take seconds. Poll rather than guess (3 s was too short).
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-JLSamplerProcess) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        $s = Get-JLSamplerProcess
        if ($s) {
            Write-Host "Still running after 20 s (pid $($s.ProcessId)); stopping it directly."
            Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue
        }
        # A force-kill skips the sampler's finally block, which is what stops
        # its nvidia-smi logger. Clean up any logger writing into DataDir.
        $escaped = [regex]::Escape($DataDir)
        Get-CimInstance Win32_Process -Filter "Name='nvidia-smi.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $escaped } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Stopped orphaned nvidia-smi logger (pid $($_.ProcessId))." }
        Remove-Item -LiteralPath (Join-Path $DataDir 'STOP') -Force -ErrorAction SilentlyContinue
        Write-Host "Sampler stopped."
    }

    'diff' {
        $g = if ($Good) { $Good } else { (Get-JLLatestSnapshot -Label 'good').FullName }
        $b = if ($Bad)  { $Bad }  else { (Get-JLLatestSnapshot -Label 'jitter').FullName }
        if (-not $g -or -not $b) {
            throw "Need one 'good' and one 'jitter' snapshot. Capture them with: .\JitterLab.ps1 snapshot good  /  .\JitterLab.ps1 snapshot jitter"
        }
        Show-JLDiff -GoodPath $g -BadPath $b -IncludeNoise:$IncludeNoise
    }

    'trace' {
        Assert-JLDataDirSane
        $label = if ($Arg) { $Arg } else { 'manual' }
        Invoke-JLTrace -Config $Config -KitRoot $KitRoot -DataDir $DataDir -Label $label -Seconds $Seconds | Out-Null
        Invoke-JLRetention -Config $Config -DataDir $DataDir | Out-Null
    }

    'presentmon' {
        Assert-JLDataDirSane
        $label = if ($Arg) { $Arg } else { 'manual' }
        $r = Invoke-JLPresentMon -Config $Config -KitRoot $KitRoot -DataDir $DataDir -Label $label -Seconds $Seconds
        Write-Host ""
        Write-Host "Presentation modes seen:"
        Get-JLPresentModeSummary -CsvPath $r.Path | Format-Table -AutoSize
        Invoke-JLRetention -Config $Config -DataDir $DataDir | Out-Null
    }

    'clean' {
        $r = Invoke-JLRetention -Config $Config -DataDir $DataDir -WhatIfOnly:$WhatIfOnly
        Write-Host "Data dir: $DataDir"
        Write-Host "  before : $($r.StartMB) MB"
        Write-Host "  after  : $($r.EndMB) MB  (budget $($Config.MaxDataMB) MB)"
        Write-Host "  removed: $($r.Deleted.Count) file(s)$(if ($WhatIfOnly) { ' [dry run - nothing deleted]' })"
        if ($r.Warning) { Write-Warning $r.Warning }
    }

    'pack' {
        # Bundle the kit (code + docs) for sharing, optionally with findings.
        $out = if ($Arg) { $Arg } else { Join-Path $KitRoot ("jitter-lab-$Version-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.zip') }
        if ($out -match $SyncedPattern -and -not $Force) {
            Write-Warning "Writing the zip into a synced folder: $out"
        }
        $staging = Join-Path $env:TEMP ("jitterlab-pack-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            foreach ($item in 'lib', 'docs', 'profiles', 'JitterLab.ps1', 'jitterlab.cmd', 'config.psd1', 'README.md', 'CHANGELOG.md', 'Test-JitterLab.ps1') {
                $src = Join-Path $KitRoot $item
                if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $staging -Recurse -Force }
            }
            # bin\ is deliberately excluded: PresentMon is a third-party binary,
            # redistribute by pointing people at Intel's release instead.
            Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $out -Force
            Write-Host "Packed: $out"
            Write-Host "Note: bin\PresentMon.exe is NOT included. See docs\ELEVATED-STEPS.md for where to get it."
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    'selftest' {
        & (Join-Path $KitRoot 'Test-JitterLab.ps1')
    }
}
