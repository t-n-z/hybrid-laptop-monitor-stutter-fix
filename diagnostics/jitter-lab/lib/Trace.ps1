# ---------------------------------------------------------------------------
# Trace.ps1 - ETW capture via the in-box wpr.exe. NEEDS ELEVATION.
#
# This is the deep view: every present call, flip-queue state, vblank timing
# and DMA packet, from the DxgKrnl and Dwm-Core providers. It is the layer
# where "the compositor is missing vertical blanks" is either visible or not.
#
# Use it as a MATCHED PAIR: one capture while it is juddering, one after
# Ctrl+Alt+D has fixed it. Same machine, minutes apart, one variable. That
# comparison is worth far more than either trace alone.
#
# Buffers are capped by profiles\jitterlab.wprp so a capture cannot blow the
# disk budget. The built-in profiles are a fallback and are NOT capped - they
# can produce several hundred MB.
#
# Reading an ETL properly needs Windows Performance Analyzer, which is a
# separate download (Windows ADK). Capture now, analyse later: the ETL is the
# perishable evidence, WPA can be installed any time.
# ---------------------------------------------------------------------------

function Test-JLElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-JLTraceStatus {
    # PS 5.1: under EAP=Stop, native stderr becomes a terminating error, and wpr
    # writes progress to stderr. Scope Continue to this function only.
    $ErrorActionPreference = 'Continue'
    try {
        $out = & wpr.exe -status 2>&1 | Out-String
        return [pscustomobject]@{
            Running = ($out -notmatch 'not recording')
            Raw     = $out.Trim()
        }
    } catch {
        return [pscustomobject]@{ Running = $false; Raw = "wpr -status failed: $($_.Exception.Message)" }
    }
}

function Start-JLTrace {
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string]    $KitRoot,
        [switch] $UseFallbackProfiles
    )
    $ErrorActionPreference = 'Continue'   # see Get-JLTraceStatus
    if (-not (Test-JLElevated)) { throw 'Start-JLTrace needs an elevated PowerShell. See docs\ELEVATED-STEPS.md.' }

    $st = Get-JLTraceStatus
    if ($st.Running) { throw "A WPR recording is already running. Stop it first: wpr -cancel  (or jitterlab trace-stop)." }

    $wprArgs = @()
    $profilePath = Join-Path $KitRoot $Config.WprProfile.Split('!')[0]
    if (-not $UseFallbackProfiles -and (Test-Path -LiteralPath $profilePath)) {
        $profileName = $Config.WprProfile.Split('!')[1]
        $wprArgs += @('-start', "$profilePath!$profileName")
    } else {
        foreach ($p in $Config.WprFallback) { $wprArgs += @('-start', $p) }
    }

    $out = & wpr.exe @wprArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "wpr start failed (exit $LASTEXITCODE): $($out.Trim())" }
    return $out.Trim()
}

function Stop-JLTrace {
    param(
        [Parameter(Mandatory)] [string] $DataDir,
        [ValidateSet('jitter', 'good', 'manual')] [string] $Label = 'manual'
    )
    $ErrorActionPreference = 'Continue'   # see Get-JLTraceStatus
    if (-not (Test-JLElevated)) { throw 'Stop-JLTrace needs an elevated PowerShell.' }

    $dir = Join-Path $DataDir 'traces'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $etl = Join-Path $dir ('trace-{0}-{1}.etl' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $Label)

    $out = & wpr.exe -stop $etl 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "wpr stop failed (exit $LASTEXITCODE): $($out.Trim())" }

    $mb = if (Test-Path -LiteralPath $etl) { [math]::Round((Get-Item -LiteralPath $etl).Length / 1MB, 1) } else { 0 }
    return [pscustomobject]@{ Path = $etl; SizeMB = $mb; Raw = $out.Trim() }
}

function Invoke-JLTrace {
    <#  Start, wait, stop. The whole capture in one call, which is what you
        want when the screen is juddering and you are not in the mood to type.  #>
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string]    $KitRoot,
        [Parameter(Mandatory)] [string]    $DataDir,
        [ValidateSet('jitter', 'good', 'manual')] [string] $Label = 'manual',
        [int] $Seconds = 0
    )
    if ($Seconds -le 0) { $Seconds = $Config.TraceSeconds }

    Write-Host "Starting ETW capture ($Seconds s, label=$Label)..."
    Start-JLTrace -Config $Config -KitRoot $KitRoot | Out-Null

    # Give the trace something to chew on: if the user drags a window during
    # these seconds the difference between broken and healthy is far clearer.
    Write-Host "  -> Drag a window around and scroll for the next $Seconds seconds."
    Start-Sleep -Seconds $Seconds

    $r = Stop-JLTrace -DataDir $DataDir -Label $Label
    Write-Host "Captured: $($r.Path)  ($($r.SizeMB) MB)"
    return $r
}

function Stop-JLTraceHard {
    <#  Cancel a recording without writing an ETL. Use if a capture was started
        by mistake, or if a previous run left WPR recording.  #>
    $ErrorActionPreference = 'Continue'   # see Get-JLTraceStatus
    if (-not (Test-JLElevated)) { throw 'Needs an elevated PowerShell.' }
    $out = & wpr.exe -cancel 2>&1 | Out-String
    return $out.Trim()
}
