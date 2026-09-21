# ---------------------------------------------------------------------------
# Sampler.ps1 - the continuous, low-cost watcher. Safe to leave running.
#
# Three streams, each at its own rate so the cost stays near zero:
#   dwm.csv    - DwmGetCompositionTimingInfo deltas (default 1 s). This is the
#                one that should show the jitter directly as missed/dropped
#                frames per second. A single function call; microseconds.
#   sys.csv    - perf counters (default 5 s): per-adapter GPU use, DPC and
#                interrupt time, dwm.exe CPU/handles, free memory.
#   nvidia.csv - written by ONE persistent nvidia-smi process using its own
#                --loop flag (default 10 s). Spawning nvidia-smi repeatedly
#                would cost far more than letting it loop internally.
#
# Stops when the stop-file appears, or after -MaxMinutes. No admin rights.
# ---------------------------------------------------------------------------

function Start-JLSampler {
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string]    $DataDir,
        [int] $MaxMinutes = 0          # 0 = run until stopped
    )

    $live = Join-Path $DataDir 'live'
    if (-not (Test-Path -LiteralPath $live)) { New-Item -ItemType Directory -Path $live -Force | Out-Null }

    $stopFile = Join-Path $DataDir 'STOP'
    if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force }

    $runStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dwmCsv   = Join-Path $live "dwm-$runStamp.csv"
    $sysCsv   = Join-Path $live "sys-$runStamp.csv"
    $nvCsv    = Join-Path $live "nvidia-$runStamp.csv"
    $dispCsv  = Join-Path $live "display-$runStamp.csv"

    'timestamp,refresh_hz,compose_hz,d_frames_displayed,d_frames_dropped,d_frames_missed,d_frames_late,frames_pending,frames_outstanding,d_refreshes_displayed,d_refreshes_presented,d_buffers_empty,note' |
        Set-Content -LiteralPath $dwmCsv -Encoding ASCII
    'timestamp,gpu_nvidia_pct,gpu_intel_pct,dpc_pct,interrupt_pct,cpu_pct,avail_mb,dwm_cpu_sec,dwm_handles,dwm_threads,dwm_ws_mb' |
        Set-Content -LiteralPath $sysCsv -Encoding ASCII
    'timestamp,intel_avail,intel_mode,nvidia_avail,nvidia_mode,desktop_screens' |
        Set-Content -LiteralPath $dispCsv -Encoding ASCII

    # --- persistent nvidia-smi logger ---------------------------------------
    $nvProc = $null
    try {
        $nvq = 'timestamp,pstate,clocks.current.graphics,clocks.current.memory,clocks_event_reasons.active,' +
               'utilization.gpu,memory.used,temperature.gpu,power.draw,pcie.link.gen.current,pcie.link.width.current'
        # quoted: PS 5.1 Start-Process does not quote array items with spaces
        $nvArgs = @("--query-gpu=$nvq", '--format=csv,nounits', "-l", "$($Config.NvidiaIntervalSec)", '-f', "`"$nvCsv`"")
        $nvProc = Start-Process -FilePath 'nvidia-smi' -ArgumentList $nvArgs -WindowStyle Hidden -PassThru
    } catch {
        Add-Content -LiteralPath (Join-Path $DataDir 'sampler.log') -Value "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') nvidia-smi logger failed to start: $($_.Exception.Message)"
    }

    $deadline    = if ($MaxMinutes -gt 0) { (Get-Date).AddMinutes($MaxMinutes) } else { [datetime]::MaxValue }
    $prev        = $null
    $lastSys     = [datetime]::MinValue
    $lastSnap    = [datetime]::MinValue
    $lastJanitor = [datetime]::MinValue
    $lastDisp    = [datetime]::MinValue
    $prevIntel   = $null
    $dwmLines    = New-Object System.Collections.Generic.List[string]

    Add-Content -LiteralPath (Join-Path $DataDir 'sampler.log') -Value "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') sampler START pid=$PID run=$runStamp nvidia_pid=$($nvProc.Id)"

    try {
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $stopFile)) {
            $now = Get-Date

            # ---- DWM composition timing (the headline stream) --------------
            try {
                $t = Get-DwmTiming
                if ($prev) {
                    $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},' -f
                        $now.ToString('yyyy-MM-dd HH:mm:ss.fff'),
                        $t.RefreshHz, $t.ComposeHz,
                        ($t.CFramesDisplayed    - $prev.CFramesDisplayed),
                        ($t.CFramesDropped      - $prev.CFramesDropped),
                        ($t.CFramesMissed       - $prev.CFramesMissed),
                        ($t.CFramesLate         - $prev.CFramesLate),
                        $t.CFramesPending, $t.CFramesOutstanding,
                        ($t.CRefreshesDisplayed - $prev.CRefreshesDisplayed),
                        ($t.CRefreshesPresented - $prev.CRefreshesPresented),
                        ($t.CBuffersEmpty       - $prev.CBuffersEmpty)
                    $dwmLines.Add($line)
                }
                $prev = $t
            } catch {
                # DWM timing is unavailable on the secure desktop (UAC prompt,
                # lock screen). Expected and harmless; note it and carry on.
                $dwmLines.Add(('{0},,,,,,,,,,,,{1}' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), ($_.Exception.Message -replace ',', ';')))
                $prev = $null
            }

            if ($dwmLines.Count -ge 20) {
                Add-Content -LiteralPath $dwmCsv -Value $dwmLines -Encoding ASCII
                $dwmLines.Clear()
            }

            # ---- system counters -------------------------------------------
            if (($now - $lastSys).TotalSeconds -ge $Config.CounterIntervalSec) {
                $lastSys = $now
                try {
                    $c = Get-Counter '\Processor(_Total)\% DPC Time','\Processor(_Total)\% Interrupt Time','\Processor(_Total)\% Processor Time','\Memory\Available MBytes' -ErrorAction Stop
                    $v = @{}
                    $c.CounterSamples | ForEach-Object { $v[($_.Path -split '\\')[-1]] = [math]::Round($_.CookedValue, 3) }

                    # Split GPU use by adapter LUID. The NVIDIA adapter is the
                    # one holding dedicated memory; anything landing on the
                    # other adapter is exactly what hypothesis 1 predicts.
                    $nvPct = 0.0; $inPct = 0.0
                    $nvLuid = Get-JLNvidiaLuid
                    (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples |
                        Where-Object { $_.CookedValue -gt 0 } | ForEach-Object {
                            if ($nvLuid -and $_.InstanceName -like "*$nvLuid*") { $nvPct += $_.CookedValue } else { $inPct += $_.CookedValue }
                        }

                    $d = Get-Process dwm -ErrorAction SilentlyContinue | Select-Object -First 1
                    '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}' -f
                        $now.ToString('yyyy-MM-dd HH:mm:ss'),
                        [math]::Round($nvPct, 2), [math]::Round($inPct, 2),
                        $v['% DPC Time'], $v['% Interrupt Time'], $v['% Processor Time'], $v['Available MBytes'],
                        $(if ($d) { [math]::Round($d.CPU, 1) } else { '' }),
                        $(if ($d) { $d.HandleCount } else { '' }),
                        $(if ($d) { $d.Threads.Count } else { '' }),
                        $(if ($d) { [math]::Round($d.WorkingSet64 / 1MB, 1) } else { '' }) |
                        Add-Content -LiteralPath $sysCsv -Encoding ASCII
                } catch { }
            }

            # ---- per-adapter display state (the ghost-panel watch) ---------
            # Availability 3 = running, 8 = offline. The jitter state has the
            # Intel adapter at 3 with 1920x1080@144 while the lid is shut.
            $dispEvery = if ($Config.DisplayIntervalSec) { $Config.DisplayIntervalSec } else { 30 }
            if (($now - $lastDisp).TotalSeconds -ge $dispEvery) {
                $lastDisp = $now
                try {
                    $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
                    $in = $vc | Where-Object { $_.Name -match 'Intel' }  | Select-Object -First 1
                    $nv = $vc | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
                    $mode = { param($a) if ($a -and $a.CurrentHorizontalResolution) { '{0}x{1}@{2}' -f $a.CurrentHorizontalResolution, $a.CurrentVerticalResolution, $a.CurrentRefreshRate } else { 'none' } }
                    $scr = try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; [System.Windows.Forms.Screen]::AllScreens.Count } catch { '' }
                    '{0},{1},{2},{3},{4},{5}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'),
                        $in.Availability, (& $mode $in), $nv.Availability, (& $mode $nv), $scr |
                        Add-Content -LiteralPath $dispCsv -Encoding ASCII

                    $intelState = "$($in.Availability)/$(& $mode $in)"
                    if ($null -ne $prevIntel -and $intelState -ne $prevIntel) {
                        $msg = "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') DISPLAY STATE CHANGE intel $prevIntel -> $intelState"
                        Add-Content -LiteralPath (Join-Path $DataDir 'sampler.log') -Value $msg
                        # Snapshot the moment it happens: this is the trigger window.
                        try { Save-JLSnapshot -Dir (Join-Path $DataDir 'snapshots') -Label 'auto' | Out-Null } catch { }
                    }
                    $prevIntel = $intelState
                } catch { }
            }

            # ---- periodic full snapshot ------------------------------------
            if (($now - $lastSnap).TotalMinutes -ge $Config.SnapshotIntervalMin) {
                $lastSnap = $now
                try { Save-JLSnapshot -Dir (Join-Path $DataDir 'snapshots') -Label 'auto' | Out-Null } catch { }
            }

            # ---- disk budget -------------------------------------------------
            if (($now - $lastJanitor).TotalMinutes -ge 10) {
                $lastJanitor = $now
                try { Invoke-JLRetention -Config $Config -DataDir $DataDir | Out-Null } catch { }
            }

            # Rotate before the CSV gets unwieldy.
            foreach ($f in @($dwmCsv, $sysCsv)) {
                if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length / 1MB) -gt $Config.RotateCsvAtMB) {
                    $rot = [IO.Path]::ChangeExtension($f, $null) + '-' + $now.ToString('HHmmss') + '.csv'
                    Move-Item -LiteralPath $f -Destination $rot -Force
                    if ($f -eq $dwmCsv) {
                        'timestamp,refresh_hz,compose_hz,d_frames_displayed,d_frames_dropped,d_frames_missed,d_frames_late,frames_pending,frames_outstanding,d_refreshes_displayed,d_refreshes_presented,d_buffers_empty,note' | Set-Content -LiteralPath $f -Encoding ASCII
                    } else {
                        'timestamp,gpu_nvidia_pct,gpu_intel_pct,dpc_pct,interrupt_pct,cpu_pct,avail_mb,dwm_cpu_sec,dwm_handles,dwm_threads,dwm_ws_mb' | Set-Content -LiteralPath $f -Encoding ASCII
                    }
                }
            }

            Start-Sleep -Seconds $Config.DwmTimingIntervalSec
        }
    } finally {
        if ($dwmLines.Count) { Add-Content -LiteralPath $dwmCsv -Value $dwmLines -Encoding ASCII }
        if ($nvProc -and -not $nvProc.HasExited) { try { Stop-Process -Id $nvProc.Id -Force } catch { } }
        Add-Content -LiteralPath (Join-Path $DataDir 'sampler.log') -Value "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') sampler STOP pid=$PID"
    }
}

function Get-JLNvidiaLuid {
    <#  The NVIDIA adapter is identified as the one holding dedicated video
        memory. Cached for the life of the process: the LUID is stable until
        the adapter set changes.  #>
    if ($script:JLNvidiaLuid) { return $script:JLNvidiaLuid }
    try {
        $best = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples |
            Sort-Object CookedValue -Descending | Select-Object -First 1
        if ($best -and $best.CookedValue -gt 0 -and $best.InstanceName -match '(luid_0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)') {
            $script:JLNvidiaLuid = $matches[1]
        }
    } catch { }
    return $script:JLNvidiaLuid
}
