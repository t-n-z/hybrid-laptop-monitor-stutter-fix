<#
.SYNOPSIS
    Read-only check: is the integrated GPU driving a "ghost" display that is not
    part of your desktop? No admin rights needed. Changes nothing.

.DESCRIPTION
    On the affected machine, the stutter state looks like this:
      Intel UHD Graphics   : RUNNING, 1920x1080 @ 144   <- internal panel, lid shut
      NVIDIA RTX 3060      : RUNNING, 3840x1600 @ 143   <- the external monitor
      Desktop screens      : 1 (3840x1600)              <- the internal panel is NOT on it
    Healthy, the integrated adapter reports no display mode at all.

    Run it while the stutter is happening. If it reports GHOST, the fix in ..\fix
    is very likely to work for you.

    Exit code: 0 = no ghost, 1 = ghost detected, 2 = could not tell.

.PARAMETER AdapterMatch
    Regex for the integrated adapter's name. Default 'Intel'.

.PARAMETER SelfTest
    Run the built-in checks of the detection logic on synthetic data and exit.
#>
[CmdletBinding()]
param(
    [string] $AdapterMatch = 'Intel',
    [switch] $SelfTest
)

function Get-GhostVerdict {
    <#  Pure function, no system calls: easy to test.
        $Adapters: objects with Name, Width, Height, Refresh (Width $null = no display)
        $Screens : objects with Width, Height (the desktop's monitors)  #>
    param($Adapters, $Screens, [string] $Match)

    $igpu = @($Adapters | Where-Object { $_.Name -match $Match })
    if (-not $igpu) { return [pscustomobject]@{ Verdict = 'UNKNOWN'; Reason = "No display adapter matches '$Match'." } }

    $live = @($igpu | Where-Object { $_.Width })
    if (-not $live) { return [pscustomobject]@{ Verdict = 'CLEAN'; Reason = 'The integrated adapter is not driving any display (the healthy docked state).' } }

    $desk = @($Screens | ForEach-Object { '{0}x{1}' -f $_.Width, $_.Height })
    foreach ($a in $live) {
        $mode = '{0}x{1}' -f $a.Width, $a.Height
        if ($desk -notcontains $mode) {
            return [pscustomobject]@{
                Verdict = 'GHOST'
                Reason  = "'$($a.Name)' is driving $mode @ $($a.Refresh) Hz, but no desktop screen has that size. It is outputting to a display that is not part of your desktop - most likely the lid-closed internal panel."
            }
        }
    }
    return [pscustomobject]@{ Verdict = 'IN-USE'; Reason = 'The integrated adapter drives a display that IS on your desktop (e.g. lid open). Not the ghost state.' }
}

if ($SelfTest) {
    $fail = 0
    function Check($name, $got, $want) { if ($got -eq $want) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name (got $got, want $want)"; $script:fail++ } }
    $nv   = [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 3060 Laptop GPU'; Width = 3840; Height = 1600; Refresh = 143 }
    $inG  = [pscustomobject]@{ Name = 'Intel(R) UHD Graphics'; Width = 1920; Height = 1080; Refresh = 144 }
    $inOf = [pscustomobject]@{ Name = 'Intel(R) UHD Graphics'; Width = $null; Height = $null; Refresh = $null }
    $lg   = [pscustomobject]@{ Width = 3840; Height = 1600 }
    $lap  = [pscustomobject]@{ Width = 1920; Height = 1080 }
    Check 'ghost state (measured on the affected machine)' (Get-GhostVerdict @($inG, $nv) @($lg) 'Intel').Verdict 'GHOST'
    Check 'healthy docked state'                          (Get-GhostVerdict @($inOf, $nv) @($lg) 'Intel').Verdict 'CLEAN'
    Check 'lid open, both screens on the desktop'         (Get-GhostVerdict @($inG, $nv) @($lg, $lap) 'Intel').Verdict 'IN-USE'
    Check 'no matching adapter'                           (Get-GhostVerdict @($nv) @($lg) 'Intel').Verdict 'UNKNOWN'
    if ($fail) { Write-Host "$fail check(s) FAILED"; exit 1 }
    Write-Host 'All self-test checks passed.'; exit 0
}

# Make screen sizes come back in real pixels. Without this, a scaled display
# (125%, 150%) reports virtualised sizes and the comparison would misfire.
Add-Type -Namespace GhostDisplay -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
if (-not [GhostDisplay.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][GhostDisplay.Dpi]::SetProcessDPIAware() }

$adapters = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Width = $_.CurrentHorizontalResolution; Height = $_.CurrentVerticalResolution; Refresh = $_.CurrentRefreshRate }
})
Add-Type -AssemblyName System.Windows.Forms
$screens = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
    [pscustomobject]@{ Width = $_.Bounds.Width; Height = $_.Bounds.Height }
})

Write-Host ''
Write-Host 'Display adapters:'
foreach ($a in $adapters) {
    $m = if ($a.Width) { '{0}x{1} @ {2} Hz' -f $a.Width, $a.Height, $a.Refresh } else { 'no display' }
    Write-Host ('  {0,-40} {1}' -f $a.Name, $m)
}
Write-Host ("Desktop screens: {0}  ({1})" -f $screens.Count, (($screens | ForEach-Object { '{0}x{1}' -f $_.Width, $_.Height }) -join ', '))
Write-Host ''

$v = Get-GhostVerdict -Adapters $adapters -Screens $screens -Match $AdapterMatch
Write-Host "RESULT: $($v.Verdict)"
Write-Host "  $($v.Reason)"
if ($v.Verdict -eq 'GHOST') {
    Write-Host ''
    Write-Host '  -> This matches the documented bug. See ..\fix\Fix-GhostDisplay.ps1.'
    exit 1
}
if ($v.Verdict -eq 'UNKNOWN') { exit 2 }
exit 0
