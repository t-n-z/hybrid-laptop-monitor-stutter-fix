<#
.SYNOPSIS
    One-time setup: a hotkey (default Ctrl+Alt+D) that runs Fix-GhostDisplay.ps1
    with no UAC prompt.

.DESCRIPTION
    Run once from an elevated PowerShell. It:
      1. copies Fix-GhostDisplay.ps1 to %ProgramData%\GhostDisplayFix and locks
         that folder so only Administrators/SYSTEM can modify it. The task below
         runs elevated, so the script it runs must not be user-writable;
      2. registers an on-demand scheduled task "GhostDisplayFix" that runs the
         script with highest privileges (no trigger - it never runs by itself);
      3. creates a Start Menu shortcut with a Windows shortcut hotkey that starts
         that task. No AutoHotkey or other software needed.

    Windows registers shortcut hotkeys when Explorer loads. If the hotkey does
    nothing straight after installing, sign out and back in once.

    Uninstall:  .\Install-Hotkey.ps1 -Uninstall

.PARAMETER Hotkey
    Windows shortcut hotkey syntax, e.g. 'Ctrl+Alt+D', 'Ctrl+Alt+G'.
    Must include Ctrl+Alt (Windows requirement for shortcut hotkeys).

.PARAMETER AdapterMatch
    Passed through to Fix-GhostDisplay.ps1. Default 'Intel'.
#>
[CmdletBinding()]
param(
    [string] $Hotkey = 'Ctrl+Alt+D',
    [string] $AdapterMatch = 'Intel',
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$taskName = 'GhostDisplayFix'
$appDir   = Join-Path $env:ProgramData 'GhostDisplayFix'
$lnk      = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ghost Display Fix.lnk'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (right-click PowerShell > Run as administrator).'
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
    Write-Host 'Removed: scheduled task, Start Menu shortcut, and %ProgramData%\GhostDisplayFix (including its log).'
    return
}

if ($Hotkey -notmatch '^(?i)ctrl\+alt\+\S+$') { throw "Hotkey must look like 'Ctrl+Alt+<key>' (got '$Hotkey')." }

$src = Join-Path $PSScriptRoot 'Fix-GhostDisplay.ps1'
if (-not (Test-Path -LiteralPath $src)) { throw "Fix-GhostDisplay.ps1 not found next to this installer ($src)." }

# 1. Install the script where only admins can change it.
New-Item -ItemType Directory -Path $appDir -Force | Out-Null
Copy-Item -LiteralPath $src -Destination $appDir -Force
# Drop inherited ACLs (ProgramData lets Users create files) and grant:
# Administrators + SYSTEM full, Users read/execute. /T applies to the copied file.
& icacls.exe $appDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q | Out-Null
$target = Join-Path $appDir 'Fix-GhostDisplay.ps1'

# 2. On-demand elevated task. -WindowStyle Hidden keeps it quiet.
$user = "$env:USERDOMAIN\$env:USERNAME"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -AdapterMatch `"$AdapterMatch`""
$taskUser  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskUser -Settings $settings `
    -Description 'Cycle the integrated display adapter to clear the ghost-internal-display stutter. On demand only.' -Force | Out-Null

# 3. Start Menu shortcut carrying the hotkey.
$sh = New-Object -ComObject WScript.Shell
$s  = $sh.CreateShortcut($lnk)
$s.TargetPath   = Join-Path $env:SystemRoot 'System32\schtasks.exe'
$s.Arguments    = "/run /tn `"$taskName`""
$s.WindowStyle  = 7                                   # minimised
$s.Hotkey       = ($Hotkey -replace '(?i)ctrl', 'CTRL' -replace '(?i)alt', 'ALT').ToUpper()
$s.Description  = 'Clear the ghost-internal-display stutter'
$s.Save()

Write-Host ''
Write-Host "Installed. Press $Hotkey when the stutter appears."
Write-Host "  task     : $taskName (on demand only, never runs by itself)"
Write-Host "  script   : $target (admin-only write)"
Write-Host "  shortcut : $lnk"
Write-Host "  log      : $appDir\fix.log"
Write-Host 'If the hotkey does nothing yet, sign out and back in once.'
Write-Host 'Uninstall: .\Install-Hotkey.ps1 -Uninstall'
