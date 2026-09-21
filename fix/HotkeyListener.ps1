<#
.SYNOPSIS
    Background hotkey listener for the ghost-display fix. Installed and started
    by Install-Hotkey.ps1; you do not normally run this yourself.

.DESCRIPTION
    Registers one global hotkey with Windows (RegisterHotKey) and, when it is
    pressed, starts the on-demand scheduled task that runs Fix-GhostDisplay.ps1
    elevated. This process itself runs WITHOUT admin rights: all it can do is
    ask Task Scheduler to run that one task.

    Why not a shortcut hotkey: Windows shortcut (.lnk) hotkeys were tested and
    were never registered by Explorer on the test machine, even after an
    Explorer restart. RegisterHotKey is what AutoHotkey and similar tools use.

    Cost: one hidden powershell.exe, roughly 50 MB of RAM, no CPU while idle.
    Log: %LOCALAPPDATA%\GhostDisplayFix\hotkey.log
#>
param(
    [string] $Hotkey   = 'Ctrl+Alt+D',
    [string] $TaskName = 'GhostDisplayFix',
    # Register, release and exit: 0 = the key combination is free, 1 = taken.
    # Used by Install-Hotkey.ps1 to check before and verify after installing.
    [switch] $CheckOnly
)

$logDir = Join-Path $env:LOCALAPPDATA 'GhostDisplayFix'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'hotkey.log'
function Write-Log($m) { try { Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) } catch { } }

function ConvertTo-HotkeyCode([string] $text) {
    $mods = 0; $vk = 0
    foreach ($part in ($text -split '\+')) {
        switch -Regex ($part.Trim()) {
            '^(?i)(ctrl|control)$' { $mods = $mods -bor 0x2; continue }
            '^(?i)alt$'            { $mods = $mods -bor 0x1; continue }
            '^(?i)shift$'          { $mods = $mods -bor 0x4; continue }
            '^(?i)win$'            { $mods = $mods -bor 0x8; continue }
            '^(?i)[a-z]$'          { $vk = [int][char]$part.Trim().ToUpper(); continue }
            '^[0-9]$'              { $vk = [int][char]$part.Trim(); continue }
            '^(?i)f([1-9]|1[0-9]|2[0-4])$' { $vk = 0x6F + [int]$part.Trim().Substring(1); continue }
            default { throw "Unrecognised hotkey part '$part' in '$text'." }
        }
    }
    if (-not $vk -or -not $mods) { throw "Hotkey '$text' needs at least one modifier and one key." }
    return @{ Mods = $mods; Vk = $vk }
}

Add-Type -AssemblyName System.Windows.Forms
if (-not ('GhostDisplayHotkey' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class GhostDisplayHotkey : NativeWindow {
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;
    readonly string task;
    public int RegisterError;
    public int Presses;

    public GhostDisplayHotkey(uint mods, uint vk, string taskName) {
        task = taskName;
        CreateParams cp = new CreateParams();
        cp.Parent = new IntPtr(-3);                  // HWND_MESSAGE: message-only window, never visible
        CreateHandle(cp);
        if (!RegisterHotKey(Handle, 1, mods | MOD_NOREPEAT, vk)) { RegisterError = Marshal.GetLastWin32Error(); }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            Presses++;
            try {
                ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", "/run /tn \"" + task + "\"");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                Process.Start(psi);
            } catch { }
        }
        base.WndProc(ref m);
    }

    public void Release() { UnregisterHotKey(Handle, 1); DestroyHandle(); }
}
'@
}

try { $code = ConvertTo-HotkeyCode $Hotkey } catch { Write-Log "EXIT - $($_.Exception.Message)"; exit 2 }

$hk = New-Object GhostDisplayHotkey ([uint32]$code.Mods), ([uint32]$code.Vk), $TaskName
if ($CheckOnly) {
    $taken = [bool]$hk.RegisterError
    $hk.Release()
    if ($taken) { exit 1 } else { exit 0 }
}
if ($hk.RegisterError) {
    # 1409 = ERROR_HOTKEY_ALREADY_REGISTERED: another program owns this combination.
    Write-Log "EXIT - could not register $Hotkey (Win32 error $($hk.RegisterError); 1409 means another program already uses it)"
    $hk.Release(); exit 1
}
Write-Log "listening: $Hotkey -> task '$TaskName' (pid $PID)"
try { [System.Windows.Forms.Application]::Run() }
finally { $hk.Release(); Write-Log "stopped (pid $PID)" }
