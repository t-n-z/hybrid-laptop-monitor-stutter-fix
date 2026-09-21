# Steps that need elevation

Everything else in this kit runs as a normal user. Only two things need admin,
and both because **Windows requires it for ETW capture**, not because of any
choice made here.

| Needs UAC | Why |
|---|---|
| `jitterlab trace` | `wpr.exe` cannot start a kernel/system ETW session unelevated. |
| `jitterlab presentmon` | PresentMon traces other processes' present calls via ETW. |
| *(optional)* the scheduled task below | Would let tracing run with no prompt at all. |

Nothing here is destructive. Tracing reads events; it does not change driver,
display or system settings.

---

## Getting an elevated PowerShell

Start menu → type `powershell` → **Run as administrator** → approve the prompt,
then:

```powershell
cd "<path-to-repo>\diagnostics\jitter-lab"
```

Verify before relying on it:

```powershell
.\jitterlab.cmd status      # the "elevated" line should say True
```

---

## Capture during a jitter

```powershell
.\jitterlab.cmd trace jitter
.\jitterlab.cmd presentmon jitter
```

Each runs about 20 seconds. **Drag a window around and scroll while they run** —
an idle desktop produces a trace of nothing.

Then fix with Ctrl+Alt+D and capture the healthy twin straight away:

```powershell
.\jitterlab.cmd trace good
.\jitterlab.cmd presentmon good
```

---

## If a trace is left running

WPR allows one recording at a time. If a capture was interrupted:

```powershell
wpr -status          # is anything recording?
wpr -cancel          # discard without writing an ETL
```

---

## Optional: tracing without a UAC prompt

Same pattern as the existing `JitterFixIGPU` task, which is how Ctrl+Alt+D
already runs elevated with no prompt. **Not created — this is here for when
you want it.**

```powershell
# Run once, elevated. Creates an on-demand task; no trigger, nothing scheduled.
$kit = "C:\JitterLab\kit"   # a LOCAL, admin-only copy of this folder - see the trade-off below
$a = New-ScheduledTaskAction -Execute "powershell.exe" `
     -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$kit\JitterLab.ps1`" trace jitter"
$p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "JitterLabTrace" -Action $a -Principal $p -Settings $s `
     -Description "Capture a 20 s ETW trace of DWM composition during a jitter." -Force
```

Then from any normal prompt, or bound to a hotkey:

```
schtasks /run /tn "JitterLabTrace"
```

**Trade-off, stated plainly:** an always-available elevated task that runs a
script from a *synced* folder means anything that can write to that folder can
run code as administrator. If you want this, copy the kit to a local path such
as `C:\JitterLab\kit`, restrict that folder so only Administrators can write to
it, and point the task there.

---

## PresentMon

Staged at `bin\PresentMon.exe`. Intel, open source, from the GameTechDev
PresentMon releases on GitHub.

Flag names have changed between major versions. If a capture exits non-zero:

```powershell
.\bin\PresentMon.exe --help
```

and compare against the flags in `lib\PresentMon.ps1` (`--output_file`,
`--timed`, `--terminate_after_timed`, `--stop_existing_session`, `--no_top`).
Worth also trying `--track_hybrid_present`, which flags presents copied across
adapters — directly relevant on a hybrid laptop.

PresentMon is **not** included by `jitterlab pack`. It is Intel's binary under
its own licence; point people at the upstream release instead.

---

## Reading an ETL

Needs **Windows Performance Analyzer** from the Windows ADK — a large separate
download, not installed. There is no rush: capture the ETL while the fault is
live, install WPA whenever.

In WPA, the useful views are **GPU Utilization**, **DWM Frame Details** and
**Vsync/Present**. The question to take in: are vblank interrupts regular, and
are presents completing late relative to them?
