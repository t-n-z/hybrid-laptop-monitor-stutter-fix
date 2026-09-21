# ---------------------------------------------------------------------------
# DwmTiming.ps1 - read DWM's own composition statistics.
#
# WHY THIS MATTERS MOST: DwmGetCompositionTimingInfo is the compositor telling
# us, in its own numbers, whether it is keeping up with the display. During the
# jitter the picture judders while the hardware cursor stays smooth, which is
# the signature of DWM missing vertical blanks. These counters say so directly:
#   cFramesMissed  - composed too late for the vblank it was aimed at
#   cFramesDropped - composed but never shown
#   cFramesLate    - submitted late
#   cRefreshesDisplayed vs cRefreshesPresented - divergence = frames not landing
# No admin rights. Cost is a single function call, microseconds.
# ---------------------------------------------------------------------------

if (-not ('JitterLab.Dwm' -as [type])) {
Add-Type -Namespace JitterLab -Name Dwm -MemberDefinition @'
    [StructLayout(LayoutKind.Sequential)]
    public struct UNSIGNED_RATIO { public uint uiNumerator; public uint uiDenominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DWM_TIMING_INFO {
        public uint cbSize;
        public UNSIGNED_RATIO rateRefresh;
        public ulong qpcRefreshPeriod;
        public UNSIGNED_RATIO rateCompose;
        public ulong qpcVBlank;
        public ulong cRefresh;
        public uint  cDXRefresh;
        public ulong qpcCompose;
        public ulong cFrame;
        public uint  cDXPresent;
        public ulong cRefreshFrame;
        public ulong cFrameSubmitted;
        public uint  cDXPresentSubmitted;
        public ulong cFrameConfirmed;
        public uint  cDXPresentConfirmed;
        public ulong cRefreshConfirmed;
        public uint  cDXRefreshConfirmed;
        public ulong cFramesLate;
        public uint  cFramesOutstanding;
        public ulong cFrameDisplayed;
        public ulong qpcFrameDisplayed;
        public ulong cRefreshFrameDisplayed;
        public ulong cFrameComplete;
        public ulong qpcFrameComplete;
        public ulong cFramePending;
        public ulong qpcFramePending;
        public ulong cFramesDisplayed;
        public ulong cFramesComplete;
        public ulong cFramesPending;
        public ulong cFramesAvailable;
        public ulong cFramesDropped;
        public ulong cFramesMissed;
        public ulong cRefreshNextDisplayed;
        public ulong cRefreshNextPresented;
        public ulong cRefreshesDisplayed;
        public ulong cRefreshesPresented;
        public ulong cRefreshStarted;
        public ulong cPixelsReceived;
        public ulong cPixelsDrawn;
        public ulong cBuffersEmpty;
    }

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmGetCompositionTimingInfo(IntPtr hwnd, ref DWM_TIMING_INFO pTimingInfo);

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmIsCompositionEnabled(out bool pfEnabled);

    public static DWM_TIMING_INFO GetTiming() {
        DWM_TIMING_INFO ti = new DWM_TIMING_INFO();
        ti.cbSize = (uint)Marshal.SizeOf(typeof(DWM_TIMING_INFO));
        int hr = DwmGetCompositionTimingInfo(IntPtr.Zero, ref ti);
        if (hr != 0) { throw new System.ComponentModel.Win32Exception(hr, "DwmGetCompositionTimingInfo failed hr=0x" + hr.ToString("X8")); }
        return ti;
    }
'@
}
# Note: no -UsingNamespace here. Add-Type -MemberDefinition already emits
# "using System.Runtime.InteropServices;", and adding it again is a duplicate
# using directive, which this compiler treats as an error, not a warning.

function Get-DwmTimingStatus {
    <#  Probe whether this machine will answer at all, and with which hwnd.
        Returns the HRESULT so a CHANGE in behaviour is itself evidence.

        2026-09-21 on the test laptop: fails with hr=0x88980090 for null, desktop and
        shell window handles, unelevated, while the display is healthy. Struct
        size verified at 320 bytes, so this is the API refusing, not a
        marshalling fault. Re-probe after a reboot, after a jitter, and after
        Ctrl+Alt+D: if it ever starts or stops working, that correlation is
        worth more than the counters would have been.  #>
    $ti = New-Object 'JitterLab.Dwm+DWM_TIMING_INFO'
    $ti.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'JitterLab.Dwm+DWM_TIMING_INFO')
    $hr = [JitterLab.Dwm]::DwmGetCompositionTimingInfo([IntPtr]::Zero, [ref]$ti)
    [pscustomobject]@{
        Available  = ($hr -eq 0)
        HResult    = '0x' + $hr.ToString('X8')
        StructSize = $ti.cbSize
    }
}

function Get-DwmTiming {
    <#  Returns one raw reading plus the two rates as Hz. Throws if DWM
        composition timing is unavailable - which is the case on the test laptop
        (hr=0x88980090). Callers must handle the throw; the sampler records the
        HRESULT and carries on. See Get-DwmTimingStatus. #>
    $ti = [JitterLab.Dwm]::GetTiming()
    $refreshHz = if ($ti.rateRefresh.uiDenominator) { [double]$ti.rateRefresh.uiNumerator / $ti.rateRefresh.uiDenominator } else { 0 }
    $composeHz = if ($ti.rateCompose.uiDenominator) { [double]$ti.rateCompose.uiNumerator / $ti.rateCompose.uiDenominator } else { 0 }
    [pscustomobject]@{
        RefreshHz           = [math]::Round($refreshHz, 3)
        ComposeHz           = [math]::Round($composeHz, 3)
        QpcRefreshPeriod    = $ti.qpcRefreshPeriod
        CRefresh            = $ti.cRefresh
        CFramesDisplayed    = $ti.cFramesDisplayed
        CFramesDropped      = $ti.cFramesDropped
        CFramesMissed       = $ti.cFramesMissed
        CFramesLate         = $ti.cFramesLate
        CFramesPending      = $ti.cFramesPending
        CFramesOutstanding  = $ti.cFramesOutstanding
        CRefreshesDisplayed = $ti.cRefreshesDisplayed
        CRefreshesPresented = $ti.cRefreshesPresented
        CBuffersEmpty       = $ti.cBuffersEmpty
        CPixelsDrawn        = $ti.cPixelsDrawn
    }
}

function Test-DwmComposition {
    $enabled = $false
    $hr = [JitterLab.Dwm]::DwmIsCompositionEnabled([ref]$enabled)
    if ($hr -ne 0) { return $false }
    return $enabled
}
