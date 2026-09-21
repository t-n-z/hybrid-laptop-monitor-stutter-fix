<#
.SYNOPSIS
    One-time setup: a hotkey (default Ctrl+Alt+D) that runs Fix-GhostDisplay.ps1
    with no UAC prompt. Works immediately; no sign-out needed.

.DESCRIPTION
    Run once from an elevated PowerShell. It:
      1. copies Fix-GhostDisplay.ps1 and HotkeyListener.ps1 to
         %ProgramData%\GhostDisplayFix and locks that folder so only
         Administrators/SYSTEM can modify it (the fix task runs elevated, so the
         script it runs must not be user-writable);
      2. registers "GhostDisplayFix": an on-demand scheduled task that runs the fix
         with highest privileges. No trigger - it never runs by itself;
      3. registers "GhostDisplayFixHotkey": starts HotkeyListener.ps1 at logon,
         WITHOUT admin rights. The listener owns the hotkey and, when it is
         pressed, asks Task Scheduler to run task 2. It is started now as well;
      4. verifies the hotkey is actually held by the listener before reporting
         success.

    Cost of the listener: one hidden powershell.exe, about 50 MB RAM, idle CPU.

    Uninstall:  .\Install-Hotkey.ps1 -Uninstall

.PARAMETER Hotkey
    e.g. 'Ctrl+Alt+D', 'Ctrl+Alt+G', 'Ctrl+Shift+F9'. At least one modifier.
    The installer refuses a combination another program already uses.

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
$fixTask    = 'GhostDisplayFix'
$hotkeyTask = 'GhostDisplayFixHotkey'
$appDir     = Join-Path $env:ProgramData 'GhostDisplayFix'
$userLogDir = Join-Path $env:LOCALAPPDATA 'GhostDisplayFix'
# Shortcut hotkey used by an earlier version of this installer; removed on (un)install.
$oldLnk     = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ghost Display Fix.lnk'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (right-click PowerShell > Run as administrator).'
}

function Repair-AppDirAcl {
    # Take ownership for Administrators, then give the FOLDER inheritable ACEs
    # and make every file inside inherit them.
    # Do NOT use icacls /T with (OI)(CI) grants: on files the inheritance flags
    # are rejected while /inheritance:r still succeeds, which leaves files with
    # an EMPTY DACL - unreadable even by the elevated task. (Found in testing.)
    & takeown.exe /F $appDir /R /A /D Y 2>&1 | Out-Null
    & icacls.exe $appDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    if (Get-ChildItem -LiteralPath $appDir -Force -ErrorAction SilentlyContinue) {
        & icacls.exe (Join-Path $appDir '*') /reset /T /C /Q | Out-Null
    }
}

function Stop-Listener {
    Stop-ScheduledTask -TaskName $hotkeyTask -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'HotkeyListener\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Test-HotkeyFree([string] $listener, [string] $key) {
    # Exit 0 = free, 1 = taken. Runs the listener in -CheckOnly mode so the
    # hotkey parsing lives in exactly one place.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $listener -Hotkey $key -CheckOnly
    return ($LASTEXITCODE -eq 0)
}

if ($Uninstall) {
    Stop-Listener
    foreach ($t in $hotkeyTask, $fixTask) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force }
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $appDir) { Repair-AppDirAcl; Remove-Item -LiteralPath $appDir -Recurse -Force }
    if (Test-Path -LiteralPath $userLogDir) { Remove-Item -LiteralPath $userLogDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host 'Removed: both scheduled tasks, the hotkey listener, %ProgramData%\GhostDisplayFix and its logs.'
    return
}

foreach ($f in 'Fix-GhostDisplay.ps1', 'HotkeyListener.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f))) { throw "$f not found next to this installer." }
}

# 0. Reinstall cleanly: stop any listener from an earlier install so its key is free.
Stop-Listener
if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force }

if (-not (Test-HotkeyFree (Join-Path $PSScriptRoot 'HotkeyListener.ps1') $Hotkey)) {
    throw "$Hotkey is already used by another program. Pick another, e.g. -Hotkey Ctrl+Alt+G."
}

# 1. Install both scripts where only admins can change them.
New-Item -ItemType Directory -Path $appDir -Force | Out-Null
Repair-AppDirAcl
foreach ($f in 'Fix-GhostDisplay.ps1', 'HotkeyListener.ps1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $appDir -Force }
Repair-AppDirAcl
$fixScript      = Join-Path $appDir 'Fix-GhostDisplay.ps1'
$listenerScript = Join-Path $appDir 'HotkeyListener.ps1'

try {
    foreach ($s in $fixScript, $listenerScript) {
        $null = Get-Content -LiteralPath $s -TotalCount 1 -ErrorAction Stop
        $aces = @((Get-Acl -LiteralPath $s).Access)
        $usersWrite = $aces | Where-Object { $_.IdentityReference -match 'Users$' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData) }
        if ($aces.Count -lt 3) { throw "expected 3 inherited ACEs on $s, found $($aces.Count)" }
        if ($usersWrite) { throw "ordinary users can write to $s" }
    }
} catch {
    throw "Install verification failed: $($_.Exception.Message). Run with -Uninstall, then install again."
}

$user = "$env:USERDOMAIN\$env:USERNAME"

# 2. The elevated, on-demand fix task.
Register-ScheduledTask -TaskName $fixTask -Force `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$fixScript`" -AdapterMatch `"$AdapterMatch`"") `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew) `
    -Description 'Cycle the integrated display adapter to clear the ghost-internal-display stutter. On demand only.' | Out-Null

# 3. The unelevated hotkey listener, started at logon and now.
Register-ScheduledTask -TaskName $hotkeyTask -Force `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$listenerScript`" -Hotkey `"$Hotkey`" -TaskName `"$fixTask`"") `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)) `
    -Description "Hotkey $Hotkey for the ghost-display fix. Runs without admin rights; only starts task '$fixTask'." | Out-Null
Start-ScheduledTask -TaskName $hotkeyTask

# 4. Verify: the listener should now hold the key, so a fresh check must say "taken".
$held = $false
for ($i = 0; $i -lt 10 -and -not $held; $i++) {
    Start-Sleep -Seconds 1
    $held = -not (Test-HotkeyFree $listenerScript $Hotkey)
}
if (-not $held) {
    throw "The listener did not take $Hotkey. See $userLogDir\hotkey.log. Nothing else was changed; run with -Uninstall to remove the tasks."
}

Write-Host ''
Write-Host "Installed and verified. Press $Hotkey when the stutter appears - it works now, no sign-out needed."
Write-Host "  fix task      : $fixTask (elevated, on demand only)"
Write-Host "  hotkey task   : $hotkeyTask (at logon, no admin rights, ~50 MB RAM)"
Write-Host "  scripts       : $appDir (admin-only write)"
Write-Host "  logs          : $appDir\fix.log  and  $userLogDir\hotkey.log"
Write-Host 'Uninstall: .\Install-Hotkey.ps1 -Uninstall'
