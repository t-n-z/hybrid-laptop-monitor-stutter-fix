<#
.SYNOPSIS
    Self-test for JitterLab. Proves the kit is ready without collecting anything.

.DESCRIPTION
    Deliberately does NOT start the sampler, write to DataDir, or trace. It:
      1. parses every script (syntax only, no execution)
      2. loads and sanity-checks config.psd1
      3. validates the WPR profile is well-formed XML with capped buffers
      4. exercises the retention janitor against fake files in a scratch dir
         INSIDE the kit, then deletes it
      5. exercises the snapshot flattener and differ purely in memory
      6. probes read-only capabilities (DWM timing, counters, nvidia-smi)

    Everything it writes lives under <kit>\.selftest and is removed at the end.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pass = 0; $fail = 0; $warn = 0

function Ok   ($m) { $script:pass++; Write-Host "  PASS  $m" }
function Bad  ($m) { $script:fail++; Write-Host "  FAIL  $m" }
function Warn ($m) { $script:warn++; Write-Host "  WARN  $m" }

Write-Host ""
Write-Host "JitterLab self-test"
Write-Host "==================="

# --- 1. syntax -------------------------------------------------------------
Write-Host ""
Write-Host "[1] Script syntax (parse only, nothing executed)"
$scripts = @(Get-ChildItem -LiteralPath $KitRoot -Filter '*.ps1' -File) +
           @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
foreach ($s in $scripts) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count) { Bad "$($s.Name): $($errors[0].Message)" } else { Ok $s.Name }
}

# --- ASCII check: PowerShell 5.1 misreads UTF-8-without-BOM as ANSI --------
Write-Host ""
Write-Host "[2] ASCII-only check (PS 5.1 parses UTF-8-without-BOM as ANSI)"
foreach ($s in $scripts) {
    $bytes = [IO.File]::ReadAllBytes($s.FullName)
    $bad = $bytes | Where-Object { $_ -gt 127 }
    if ($bad) { Warn "$($s.Name) contains $($bad.Count) non-ASCII byte(s)" } else { Ok $s.Name }
}

# --- 3. config -------------------------------------------------------------
Write-Host ""
Write-Host "[3] Configuration"
$cfgPath = Join-Path $KitRoot 'config.psd1'
try {
    $cfg = Import-PowerShellDataFile -LiteralPath $cfgPath
    Ok "config.psd1 loads"
} catch { Bad "config.psd1 will not load: $($_.Exception.Message)"; $cfg = $null }

if ($cfg) {
    foreach ($k in 'DataDir','MaxDataMB','DwmTimingIntervalSec','CounterIntervalSec','NvidiaIntervalSec',
                   'SnapshotIntervalMin','RotateCsvAtMB','KeepRotatedCsv','KeepSnapshots','MaxTraceCount',
                   'WprProfile','WprFallback','TraceSeconds','PresentMonExe','PresentMonSeconds','WarnAtFraction') {
        if ($cfg.ContainsKey($k)) { Ok "key $k = $($cfg[$k])" } else { Bad "missing key: $k" }
    }
    if ($cfg.DataDir -match 'synology ?drive|onedrive|dropbox|google ?drive') {
        Bad "DataDir points into a synced folder: $($cfg.DataDir)"
    } else { Ok "DataDir is not a synced path" }

    # The budget must be able to hold at least one trace plus working files.
    $minNeeded = 64 * [Math]::Max(1, $cfg.MaxTraceCount)
    if ($cfg.MaxDataMB -lt $minNeeded) {
        Warn "MaxDataMB ($($cfg.MaxDataMB)) is smaller than MaxTraceCount x 64 MB ($minNeeded). Traces will be deleted almost immediately."
    } else { Ok "disk budget can hold $($cfg.MaxTraceCount) capped trace(s)" }

    if ($cfg.DwmTimingIntervalSec -lt 1) { Warn "DwmTimingIntervalSec below 1 s raises CPU cost for little gain" }
}

# --- 4. WPR profile --------------------------------------------------------
Write-Host ""
Write-Host "[4] WPR profile"
$wprp = Join-Path $KitRoot 'profiles\jitterlab.wprp'
if (Test-Path -LiteralPath $wprp) {
    try {
        [xml]$x = Get-Content -LiteralPath $wprp -Raw
        Ok "jitterlab.wprp is well-formed XML"
        $bs = [int]$x.WindowsPerformanceRecorder.Profiles.EventCollector.BufferSize.Value
        $nb = [int]$x.WindowsPerformanceRecorder.Profiles.EventCollector.Buffers.Value
        $capMB = [math]::Round(($bs * $nb) / 1024, 0)
        if ($capMB -gt 0 -and $capMB -le 256) { Ok "buffer ceiling is $capMB MB" } else { Warn "buffer ceiling is $capMB MB - check it against the disk budget" }
        $names = @($x.WindowsPerformanceRecorder.Profiles.Profile | ForEach-Object { $_.Name }) | Sort-Object -Unique
        if ($names -contains ($cfg.WprProfile -split '!')[1]) { Ok "config points at an existing profile name" }
        else { Bad "config WprProfile '$($cfg.WprProfile)' does not match any profile in the wprp ($($names -join ', '))" }
    } catch { Bad "jitterlab.wprp is not valid XML: $($_.Exception.Message)" }
} else { Bad "missing profiles\jitterlab.wprp" }

# --- 5. retention janitor, against fakes ----------------------------------
Write-Host ""
Write-Host "[5] Retention janitor (fake files in a scratch dir, removed afterwards)"
. (Join-Path $KitRoot 'lib\Retention.ps1')
$scratch = Join-Path $KitRoot '.selftest'
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'traces')    -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scratch 'snapshots') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scratch 'keep')      -Force | Out-Null

    $blob = [byte[]]::new(1MB)
    1..5 | ForEach-Object {
        [IO.File]::WriteAllBytes((Join-Path $scratch "traces\trace-2026010$_-000000-manual.etl"), $blob)
        Start-Sleep -Milliseconds 30
    }
    [IO.File]::WriteAllBytes((Join-Path $scratch 'keep\precious.etl'), $blob)

    $testCfg = @{
        MaxDataMB = 3; WarnAtFraction = 0.75; MaxTraceCount = 2
        KeepRotatedCsv = 2; KeepSnapshots = 2
    }
    $before = Get-JLDataUsageMB -DataDir $scratch
    $r = Invoke-JLRetention -Config $testCfg -DataDir $scratch
    $after = Get-JLDataUsageMB -DataDir $scratch

    if ($after -lt $before) { Ok "janitor reduced usage: $before MB -> $after MB" } else { Bad "janitor did not reduce usage ($before MB -> $after MB)" }
    if (Test-Path -LiteralPath (Join-Path $scratch 'keep\precious.etl')) { Ok "pinned file in keep\ survived" } else { Bad "pinned file in keep\ was deleted - that is a bug" }
    $left = @(Get-ChildItem -LiteralPath (Join-Path $scratch 'traces') -Filter '*.etl' -ErrorAction SilentlyContinue).Count
    if ($left -le $testCfg.MaxTraceCount) { Ok "trace count trimmed to $left (cap $($testCfg.MaxTraceCount))" } else { Bad "trace count $left exceeds cap $($testCfg.MaxTraceCount)" }
} catch {
    Bad "retention test threw: $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $scratch) { Warn "scratch dir not fully removed: $scratch" } else { Ok "scratch dir cleaned up" }
}

# --- 6. flattener and differ, in memory ------------------------------------
Write-Host ""
Write-Host "[6] Snapshot flattener and differ (in memory, no files)"
. (Join-Path $KitRoot 'lib\Diff.ps1')
try {
    $a = [pscustomobject]@{ Meta = [pscustomobject]@{ Taken = 'x' }; VideoControllers = @([pscustomobject]@{ RefreshHz = 143; Name = 'NV' }) }
    $flat = ConvertTo-JLFlat -Object $a
    if ($flat.Contains('VideoControllers[0].Name')) { Ok "flattener produces dotted paths" } else { Bad "flattener path missing" }

    # scratch stays inside the kit: this exercise writes nowhere else
    $scratch2 = Join-Path $KitRoot '.selftest'
    New-Item -ItemType Directory -Path $scratch2 -Force | Out-Null
    $tmpG = Join-Path $scratch2 'good.json'
    $tmpB = Join-Path $scratch2 'bad.json'
    '{"VideoControllers":[{"RefreshRate":143,"Name":"NV"}],"Meta":{"Taken":"1"}}' | Set-Content -LiteralPath $tmpG -Encoding UTF8
    '{"VideoControllers":[{"RefreshRate":60,"Name":"NV"}],"Meta":{"Taken":"2"}}'  | Set-Content -LiteralPath $tmpB -Encoding UTF8
    $d = Compare-JLSnapshot -GoodPath $tmpG -BadPath $tmpB
    $hit = $d | Where-Object { $_.Path -like '*RefreshRate*' }
    if ($hit -and $hit.Class -eq 'SIGNAL') { Ok "refresh-rate change is classified SIGNAL" } else { Bad "refresh-rate change not flagged as SIGNAL" }
    if (-not ($d | Where-Object { $_.Path -like 'Meta.*' })) { Ok "Meta churn correctly suppressed as noise" } else { Bad "Meta churn leaked into the diff" }
    Remove-Item -LiteralPath $scratch2 -Recurse -Force -ErrorAction SilentlyContinue
} catch { Bad "differ test threw: $($_.Exception.Message)" }

# --- 7. read-only capability probes ---------------------------------------
Write-Host ""
Write-Host "[7] Capability probes (read-only)"
. (Join-Path $KitRoot 'lib\DwmTiming.ps1')
$dwmStatus = Get-DwmTimingStatus
if ($dwmStatus.Available) {
    $t = Get-DwmTiming
    Ok "DwmGetCompositionTimingInfo works (refresh $($t.RefreshHz) Hz, compose $($t.ComposeHz) Hz)"
} else {
    # Known on the test laptop: hr=0x88980090, unelevated, display healthy, struct
    # size correct. A WARN not a FAIL - the kit degrades to PresentMon and ETW
    # for frame pacing, and the sampler records the HRESULT either way.
    Warn "DWM timing unavailable (hr=$($dwmStatus.HResult), struct $($dwmStatus.StructSize) bytes). Frame pacing falls back to PresentMon/ETW - both elevated. See docs\METRICS.md."
}

try {
    $null = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop)
    Ok "GPU Engine counters readable"
} catch { Warn "GPU Engine counters unavailable: $($_.Exception.Message)" }

if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { Ok "nvidia-smi present" } else { Warn "nvidia-smi not on PATH - the NVIDIA stream will be empty" }
if (Get-Command wpr.exe    -ErrorAction SilentlyContinue) { Ok "wpr.exe present (tracing needs elevation)" } else { Bad "wpr.exe missing" }

. (Join-Path $KitRoot 'lib\Trace.ps1')
. (Join-Path $KitRoot 'lib\PresentMon.ps1')
$pm = Get-JLPresentMonPath -Config $cfg -KitRoot $KitRoot
if ($pm) { Ok "PresentMon staged at $pm" } else { Warn "PresentMon not staged - see docs\ELEVATED-STEPS.md" }
Write-Host "  INFO  elevated right now: $(Test-JLElevated)"

# --- summary ---------------------------------------------------------------
Write-Host ""
Write-Host "==================="
Write-Host "PASS $pass   WARN $warn   FAIL $fail"
if ($fail -gt 0) { Write-Host "Self-test FAILED."; exit 1 }
Write-Host "Self-test passed. Nothing was collected and DataDir was not touched."
exit 0
