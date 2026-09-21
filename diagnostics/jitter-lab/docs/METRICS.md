# Metrics: what each number means, and what "bad" looks like

Ordered by how likely it is to crack the case.

---

## 1. DWM composition timing: intended headline, DOES NOT WORK HERE

Source: `DwmGetCompositionTimingInfo` (dwmapi.dll), sampled every second into
`live\dwm-*.csv`. No admin. Cost is microseconds.

> **Status on the test laptop, 2026-09-21: unavailable.** The call returns
> `hr=0x88980090` with a null, desktop or shell window handle, unelevated,
> while the display was healthy. `Marshal.SizeOf` on the struct is 320 bytes
> and the value round-trips intact, so this is not a marshalling fault; the
> API is declining to answer on this machine.
>
> **Consequence:** frame pacing must come from PresentMon or ETW, both of which
> need elevation. There is no unelevated frame-pacing metric on this box.
>
> **Why it is still sampled every second:** the HRESULT is recorded in the
> `note` column. If it ever starts working (after a reboot, during a jitter,
> after Ctrl+Alt+D), that change is itself a finding, and a more interesting
> one than a healthy counter would have been. Untested: whether it succeeds in
> an elevated process. Worth one probe on the next elevated pass.

The rest of this section describes what the columns mean **if** the API starts
answering, on this machine or another.

This is the compositor reporting on itself. The symptom (composited content
juddering while the hardware cursor stays smooth) *is* the definition of DWM
failing to land frames on vertical blanks. These counters either show that or
they do not, and either answer is worth having.

| Column | Meaning | What bad looks like |
|---|---|---|
| `refresh_hz` | Display refresh DWM believes it is driving | Anything other than ~143 Hz. A silent drop to 60 would explain everything. |
| `compose_hz` | Rate DWM is actually composing at | Materially below `refresh_hz` during a jitter. **This is the single most diagnostic pair of numbers in the kit.** |
| `d_frames_missed` | Frames composed too late for their target vblank, per sample | Near zero when healthy. A sustained non-zero rate during a jitter would confirm the compositor is behind. |
| `d_frames_dropped` | Frames composed but never displayed | As above. |
| `d_frames_late` | Frames submitted late | As above. |
| `frames_pending` / `frames_outstanding` | Queue depth at the moment of sampling | Persistently elevated = backing up. |
| `d_refreshes_displayed` vs `d_refreshes_presented` | Refreshes that showed a frame vs refreshes with a frame presented | Divergence = frames presented but not landing. |
| `d_buffers_empty` | Times the compositor had nothing to show | Rising = starvation rather than overload. A useful discriminator: starvation and overload look identical on screen. |

**How to read it:** compare a jitter window against a healthy window from the
same session. If missed/dropped stay at zero through a visible judder, then DWM
thinks it is fine and the fault is downstream, in scanout or the display
pipeline, which would be a major narrowing.

**Known gap:** returns an error on the secure desktop (UAC prompt, lock screen).
Those rows are written with the error in the `note` column. Expected.

---

## 2. State snapshots: the good-vs-bad diff

Source: `Snapshot.ps1`, every 15 minutes into `snapshots\`, plus on demand.
Read-only, no admin.

The fault takes 3-5 hours to appear. A trace of the broken state alone has
nothing to compare against. Snapshots make the question answerable: **what is
different between the machine at 04:00 and the same machine at 07:15?**

Captured, and why:

- **Display modes and topology** (`Win32_VideoController`, `Screen.AllScreens`,
  `WmiMonitorID`): a silent mode or topology change is the most direct
  possible explanation.
- **`GraphicsDrivers\Configuration` subkey list**: Windows records each display
  topology it has seen. A new or changed set between good and bad would be a
  direct hit on the topology-rebuild theory.
- **DWM registry key**: `OverlayTestMode` is 5 on this machine (MPO disabled).
  If anything ever changes it, that shows here.
- **Per-process GPU adapter LUID**: which adapter each process is rendering on.
  A process migrating to the Intel adapter is exactly what hypothesis 1
  predicts. Note the limitation: only processes using a GPU *engine* during the
  sample appear, so absence is weak evidence.
- **PnP status of both display devices**: an adapter entering a degraded state.
- **`dwm.exe` handles, threads, working set**: a slow resource leak in the
  compositor over hours would show as monotonic growth. This is one of the
  better fits for a fault that needs hours to appear.
- **Services**: the NVIDIA containers, `UxSms` (the DWM session manager).
- **Process inventory**: what appeared between the last good and the first bad.

`JitterLab.ps1 diff` splits differences into **SIGNAL** (should not drift
during a session) and **noise** (counters, utilisation, timestamps). Start with
SIGNAL. If it is empty, re-run with `-IncludeNoise` before concluding nothing
changed; the classifier is a heuristic, not gospel.

---

## 3. NVIDIA telemetry

Source: one persistent `nvidia-smi --loop` process into `live\nvidia-*.csv`.

| Field | Why it is here |
|---|---|
| `pstate`, `clocks.current.*` | Already checked on 2026-09-21: pinned at P0 1425/7001 through a jitter, so power management is **disconfirmed**. Kept to make sure that stays true. |
| `clocks_event_reasons.active` | The bitmask of *why* clocks are where they are. An unexpected throttle reason appearing after hours would be a genuine finding. |
| `pcie.link.gen.current` / `width.current` | Baseline is **gen 4 x8**. A drop to gen 1, or to x4, would starve cross-adapter traffic and is a real candidate for a fault that develops over time. |
| `memory.used` | 1.6 GB of 6 GB during a jitter, so VRAM pressure is **disconfirmed**. Cheap to keep watching. |
| `temperature.gpu`, `power.draw` | Rules thermal out, or in. |

---

## 4. System counters

Source: `Get-Counter` every 5 s into `live\sys-*.csv`.

- `gpu_nvidia_pct` / `gpu_intel_pct`: GPU engine use split by adapter LUID. The
  continuous version of the per-process adapter check.
- `dpc_pct`, `interrupt_pct`: measured at 0.00% and 0.39% during a jitter, so a
  DPC storm is **disconfirmed**. Sampled continuously in case it ever isn't.
- `dwm_handles`, `dwm_threads`, `dwm_ws_mb`, `dwm_cpu_sec`: the leak watch.
- `avail_mb`: memory pressure.

**Limitation:** `% DPC Time` is a coarse proxy. True DPC latency needs a kernel
driver; the ETW trace is the right instrument if DPCs ever look implicated.

---

## 5. ETW trace (elevated)

Source: `wpr.exe` with `profiles\jitterlab.wprp`, capped at 64 MB.

Providers and what they answer:

- **`Microsoft-Windows-DxgKrnl`**: presents, flip queue, vblank/VSync
  interrupts, DMA packets, adapter events. Answers: are vblank interrupts
  regular? Are presents queued on time and completing late?
- **`Microsoft-Windows-Dwm-Core`**: the compositor's frame lifecycle, the
  detailed version of section 1.
- **`Microsoft-Windows-Dwm-Api`**: what applications are asking of DWM.
- **`Microsoft-Windows-DXGI`**: swap chain creation and presentation-mode
  changes. Directly relevant to the composed-flip/independent-flip theory.

Always capture in **matched pairs**: one during the jitter, one after Ctrl+Alt+D.

Reading the ETL needs Windows Performance Analyzer (Windows ADK), a separate
download. Capture first: the ETL is the perishable evidence and WPA can be
installed whenever.

---

## 6. PresentMon (elevated)

Source: `bin\PresentMon.exe`, Intel, open source.

Reports per window: presentation mode (`Composed: Flip` vs `Hardware Composed:
Independent Flip`), frame times, display latency, and with
`--track_hybrid_present`, presents copied across adapters.

Why it matters: the leading external theory for this class of judder is DWM
oscillating swap chains between those two modes based on perceived frame rate
(documented for Windows 11 24H2/25H2; this machine is Windows 10 22H2, so the
version match is wrong even though the symptom match is excellent). PresentMon
settles it - and on the test laptop it showed a different mechanism: see
`../../../EVIDENCE.md`. `Get-JLPresentModeSummary`
boils a capture down to process, mode and frame count for direct comparison
between the jitter capture and the healthy one.

---

## What is NOT measured, and why

- **Per-rail voltages**: not exposed on this laptop without HP's own tooling.
  GPU-level power draw is the closest available.
- **Display link/DP lane state**: no vendor-neutral API. The dock and cable
  have already been effectively ruled out by replug and monitor power-cycle
  tests failing.
- **True DPC/ISR latency**: needs a kernel driver (LatencyMon or similar). The
  ETW trace covers this ground adequately for now.
- **Panel-side frame delivery**: would need a camera or a hardware capture
  device. If DWM's counters ever look clean through a visible judder, this
  becomes the next thing worth solving.
