# ---------------------------------------------------------------------------
# Snapshot.ps1 - one full read-only state dump, for good-vs-bad diffing.
#
# WHY: the jitter takes 3-5 hours of ordinary uptime to appear. A trace taken
# only while it is broken has nothing to compare against. Snapshots taken every
# 15 minutes let us diff the last good state against the first bad one and see
# what actually changed. That is the single most likely route to root cause.
#
# Strictly read-only: queries and registry reads only. No admin rights needed.
# ---------------------------------------------------------------------------

function Get-JLSnapshot {
    param([switch]$IncludeNvidiaFull)

    $ErrorActionPreference = 'SilentlyContinue'
    $os   = Get-CimInstance Win32_OperatingSystem
    $snap = [ordered]@{}

    $snap.Meta = [ordered]@{
        Taken       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        TakenUtc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Host        = $env:COMPUTERNAME
        BootTime    = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
        UptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 3)
        OsBuild     = "$($os.Version) $($os.BuildNumber)"
        SchemaVer   = 1
    }

    # --- DWM composition statistics (the headline metric) -------------------
    $snap.DwmTiming = try { Get-DwmTiming } catch { @{ Error = $_.Exception.Message } }
    $snap.DwmCompositionEnabled = try { Test-DwmComposition } catch { $null }

    # --- display adapters and current modes ---------------------------------
    $snap.VideoControllers = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [ordered]@{
            Name          = $_.Name
            PNPDeviceID   = $_.PNPDeviceID
            DriverVersion = $_.DriverVersion
            DriverDate    = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null }
            HorizRes      = $_.CurrentHorizontalResolution
            VertRes       = $_.CurrentVerticalResolution
            RefreshRate   = $_.CurrentRefreshRate
            MinRefresh    = $_.MinRefreshRate
            MaxRefresh    = $_.MaxRefreshRate
            BitsPerPel    = $_.CurrentBitsPerPixel
            VideoMode     = $_.VideoModeDescription
            Availability  = $_.Availability
            Status        = $_.Status
            ConfigMgrErr  = $_.ConfigManagerErrorCode
        }
    })

    # --- PnP state of every display-class device ----------------------------
    $snap.DisplayDevices = @(Get-PnpDevice -Class Display | ForEach-Object {
        [ordered]@{ Name = $_.FriendlyName; InstanceId = $_.InstanceId; Status = $_.Status; Problem = "$($_.Problem)" }
    })

    # --- attached monitors ---------------------------------------------------
    $snap.Monitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | ForEach-Object {
        $nm = if ($_.UserFriendlyName) { -join ($_.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }) } else { $null }
        [ordered]@{ Name = $nm; Active = $_.Active; InstanceName = $_.InstanceName }
    })

    # --- desktop metrics (topology changes show up here) --------------------
    $snap.Screens = @(try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            [ordered]@{ Device = $_.DeviceName; Primary = $_.Primary; Bounds = "$($_.Bounds)"; WorkingArea = "$($_.WorkingArea)"; BitsPerPixel = $_.BitsPerPixel }
        }
    } catch { @() })

    # --- registry state that governs composition ----------------------------
    $snap.Registry = [ordered]@{}

    # Skip the huge static GPU blacklists: they never change and bloat the diff.
    $snap.Registry.Dwm = try {
        $o = [ordered]@{}
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm').PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' -and $_.Name -notlike '*Blacklist' } |
            Sort-Object Name | ForEach-Object { $o[$_.Name] = "$($_.Value)" }
        $o
    } catch { @{} }

    $snap.Registry.GraphicsDrivers = try {
        $o = [ordered]@{}
        (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers').PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            Sort-Object Name | ForEach-Object { $o[$_.Name] = "$($_.Value)" }
        $o
    } catch { @{} }

    # Display topology sets Windows has recorded. A new or changed set between
    # a good and a bad snapshot would be a direct hit on the topology theory.
    $snap.Registry.DisplayConfigSets = @(try {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration' -ErrorAction Stop |
            ForEach-Object { $_.PSChildName } | Sort-Object
    } catch { @() })

    $snap.Registry.UserGpuPreferences = try {
        $o = [ordered]@{}
        (Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction Stop).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            Sort-Object Name | ForEach-Object { $o[$_.Name] = "$($_.Value)" }
        $o
    } catch { @{} }

    # --- which GPU each process is actually using ---------------------------
    # Counter instance names carry the adapter LUID, so a process moving between
    # the Intel and NVIDIA adapters is visible here.
    $snap.GpuEngine = @(try {
        (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples |
            Where-Object { $_.CookedValue -gt 0 } |
            ForEach-Object {
                $inst   = $_.InstanceName
                $procId = if ($inst -match 'pid_(\d+)') { [int]$matches[1] } else { $null }
                $luid   = if ($inst -match '(luid_0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)') { $matches[1] } else { $null }
                $eng    = if ($inst -match 'engtype_(\w+)') { $matches[1] } else { $null }
                [ordered]@{
                    Pid     = $procId
                    Luid    = $luid
                    Engine  = $eng
                    Process = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
                    Util    = [math]::Round($_.CookedValue, 2)
                }
            } | Sort-Object -Property @{ Expression = { $_.Util } } -Descending | Select-Object -First 40
    } catch { @() })

    $snap.GpuAdapterMemory = @(try {
        (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples |
            ForEach-Object { [ordered]@{ Adapter = $_.InstanceName; DedicatedMB = [math]::Round($_.CookedValue / 1MB, 1) } }
    } catch { @() })

    # --- system-level contention proxies ------------------------------------
    $snap.SystemCounters = try {
        $o = [ordered]@{}
        (Get-Counter '\Processor(_Total)\% DPC Time','\Processor(_Total)\% Interrupt Time','\Processor(_Total)\% Processor Time','\System\Context Switches/sec','\Memory\Available MBytes' -ErrorAction Stop).CounterSamples |
            ForEach-Object { $o[($_.Path -replace '^\\\\[^\\]+', '')] = [math]::Round($_.CookedValue, 3) }
        $o
    } catch { @{} }

    # --- NVIDIA telemetry ----------------------------------------------------
    # Includes PCIe link gen/width and clock event reasons: a link dropping gen
    # or width, or an unexpected throttle reason appearing after hours of
    # uptime, would be a real finding.
    $snap.Nvidia = try {
        $q = 'clocks.current.graphics,clocks.current.memory,clocks.current.sm,clocks.current.video,' +
             'clocks_event_reasons.active,clocks_event_reasons.gpu_idle,clocks_event_reasons.sw_power_cap,' +
             'clocks_event_reasons.hw_slowdown,clocks_event_reasons.sw_thermal_slowdown,' +
             'pstate,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,' +
             'power.draw,power.limit,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max'
        $csv  = & nvidia-smi --query-gpu=$q --format=csv,noheader 2>$null
        $keys = $q -split ','
        $vals = "$($csv | Select-Object -First 1)" -split ',\s*'
        $o = [ordered]@{}
        for ($i = 0; $i -lt $keys.Count -and $i -lt $vals.Count; $i++) { $o[$keys[$i]] = $vals[$i] }
        $o
    } catch { @{} }

    if ($IncludeNvidiaFull) {
        $snap.NvidiaFull = try { (& nvidia-smi -q 2>$null) -join "`n" } catch { $null }
    }

    # --- key processes and services -----------------------------------------
    # Handle and thread counts on dwm.exe are worth watching: a slow leak in the
    # compositor over hours would be visible as monotonic growth.
    $snap.KeyProcesses = @(try {
        Get-Process dwm, csrss, explorer, nvcontainer -ErrorAction SilentlyContinue |
            ForEach-Object {
                [ordered]@{
                    Name         = $_.ProcessName
                    Pid          = $_.Id
                    Start        = if ($_.StartTime) { $_.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
                    Handles      = $_.HandleCount
                    Threads      = $_.Threads.Count
                    WorkingSetMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
                    CpuSec       = if ($null -ne $_.CPU) { [math]::Round($_.CPU, 1) } else { $null }
                }
            }
    } catch { @() })

    # NVDisplay.Container has a dot in the name, so query it separately.
    $snap.NvDisplayContainers = @(try {
        Get-CimInstance Win32_Process -Filter "Name='NVDisplay.Container.exe'" |
            ForEach-Object { [ordered]@{ Pid = $_.ProcessId; Session = $_.SessionId; Created = "$($_.CreationDate)" } }
    } catch { @() })

    $snap.Services = @(try {
        Get-Service NvContainerLocalSystem, 'NVDisplay.ContainerLocalSystem', UxSms, Themes -ErrorAction SilentlyContinue |
            ForEach-Object { [ordered]@{ Name = $_.Name; Status = "$($_.Status)"; StartType = "$($_.StartType)" } }
    } catch { @() })

    # --- full process inventory, for spotting what appeared between snapshots
    $snap.ProcessInventory = @(try {
        Get-Process | Group-Object ProcessName | Sort-Object Name |
            ForEach-Object { [ordered]@{ Name = $_.Name; Count = $_.Count } }
    } catch { @() })

    $snap.PowerScheme = try { "$((& powercfg /getactivescheme) -join ' ')".Trim() } catch { $null }

    return $snap
}

function Save-JLSnapshot {
    param(
        [Parameter(Mandatory)] [string] $Dir,
        [ValidateSet('auto', 'good', 'jitter')] [string] $Label = 'auto',
        [switch] $IncludeNvidiaFull
    )
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $snap = Get-JLSnapshot -IncludeNvidiaFull:$IncludeNvidiaFull
    $snap.Meta.Label = $Label
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path  = Join-Path $Dir "snap-$stamp-$Label.json"
    $snap | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
