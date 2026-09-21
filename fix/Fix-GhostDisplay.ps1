<#
.SYNOPSIS
    Clears the "ghost internal display" desktop stutter on hybrid-graphics laptops
    by briefly disabling and re-enabling the integrated (Intel) display adapter.

.DESCRIPTION
    Symptom this fixes: laptop docked with the lid closed, external monitor on the
    discrete GPU. After the external monitor turns off / sleeps and comes back,
    windows, scrolling and app-drawn cursors stutter while the normal mouse cursor
    stays smooth. Only a reboot used to clear it.

    Cause (proven on the test machine, see EVIDENCE.md): when the external monitor
    disappears, Windows promotes the lid-closed internal panel on the integrated
    GPU, and does not demote it when the external monitor returns. That live but
    invisible display path makes the Desktop Window Manager stall.

    This script removes the ghost by cycling the integrated adapter. Expect a
    1-2 second black screen; the stutter is usually gone before the picture
    returns.

    SAFETY
    - Refuses to run unless a DIFFERENT adapter is already driving a display, so
      it cannot black out a machine whose only screen is on the integrated GPU.
    - The re-enable is in a finally block: an error part-way through still puts
      the adapter back.
    - Changes no settings. Nothing persists after it finishes.

.PARAMETER AdapterMatch
    Regex matched against the display adapter's name. Default 'Intel'.
    AMD-iGPU laptops: try 'AMD Radeon\(TM\) Graphics' (untested - see README).

.PARAMETER OffSeconds
    How long the adapter stays disabled. Default 3.

.NOTES
    Needs an elevated PowerShell (Device Manager changes require admin).
    Install-Hotkey.ps1 wraps this in a scheduled task so a hotkey runs it with
    no UAC prompt. Log: %ProgramData%\GhostDisplayFix\fix.log
#>
[CmdletBinding()]
param(
    [string] $AdapterMatch = 'Intel',
    [ValidateRange(1, 30)] [int] $OffSeconds = 3
)

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated  = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$logDir = Join-Path $env:ProgramData 'GhostDisplayFix'
$log    = Join-Path $logDir 'fix.log'
function Write-Log($m) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    # Only elevated runs touch ProgramData. An unelevated run creating the
    # folder first would leave it user-owned before the installer locks it.
    if (-not $elevated) { return }
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -LiteralPath $log -Value $line
    } catch { }
}

if (-not $elevated) {
    Write-Log 'ABORT - needs an elevated PowerShell (Run as administrator), or install the hotkey with Install-Hotkey.ps1.'
    exit 1
}

$dev = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue |
       Where-Object { $_.FriendlyName -match $AdapterMatch } | Select-Object -First 1
if (-not $dev) {
    Write-Log "ABORT - no healthy display adapter matching '$AdapterMatch'. (Already disabled? Re-enable it in Device Manager.)"
    exit 1
}

# Guard: another adapter must already be driving a display, or disabling this
# one would leave the machine with no picture for the duration.
$others = @(Get-CimInstance Win32_VideoController | Where-Object {
    $_.Name -notmatch $AdapterMatch -and $_.CurrentHorizontalResolution
})
if (-not $others) {
    Write-Log "ABORT - no other adapter is driving a display. Your screen appears to run on '$($dev.FriendlyName)' itself, so this fix does not apply and would black it out."
    exit 1
}

$os = Get-CimInstance Win32_OperatingSystem
Write-Log ('RUN target="{0}" uptime={1:N1}h other_display="{2} {3}x{4}"' -f $dev.FriendlyName,
    ((Get-Date) - $os.LastBootUpTime).TotalHours, $others[0].Name,
    $others[0].CurrentHorizontalResolution, $others[0].CurrentVerticalResolution)

try {
    Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
    Write-Log 'disabled (this is the step that clears the stutter)'
    Start-Sleep -Seconds $OffSeconds
} catch {
    Write-Log ('disable FAILED: ' + $_.Exception.Message)
} finally {
    try {
        Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-Log ('re-enabled, status=' + (Get-PnpDevice -InstanceId $dev.InstanceId).Status)
    } catch {
        Write-Log ('*** RE-ENABLE FAILED: ' + $_.Exception.Message + ' - re-enable the adapter in Device Manager ***')
        exit 2
    }
}
exit 0
