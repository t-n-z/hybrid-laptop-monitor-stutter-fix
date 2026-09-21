# JitterLab

Instrumentation kit for the hybrid-laptop docked-display stutter (see `../../README.md`). Built 2026-09-21.
Used to find the root cause documented in `../../EVIDENCE.md`. Diagnostic only - the fix lives in `../../fix/`.

## The bug, in one paragraph

Laptop docked, lid closed, external monitor on the NVIDIA GPU. After the monitor
turns off or sleeps and comes back, everything composited starts to judder:
windows, scrolling, CAD crosshairs. The hardware mouse cursor stays perfectly
smooth. Dragging a window buys 1-5 seconds of relief, then it returns. This kit
is how the cause was found: Windows leaves the lid-closed internal panel live on
the Intel adapter, and DWM stalls on it. Full story and data:
[`../../EVIDENCE.md`](../../EVIDENCE.md). The fix: [`../../fix/`](../../fix/).

Use this kit to check whether your machine shows the same thing, or to add your
own measurements to the issue tracker.

## What it measures, and why

| Stream | What it tells us | Cost | Elevation |
|---|---|---|---|
| **DWM composition timing** ⚠ | The compositor's own count of frames **missed**, **dropped** and **late**. Would have been the headline metric. **It does not work on this machine**: `DwmGetCompositionTimingInfo` returns `hr=0x88980090` regardless of window handle, verified 2026-09-21 while healthy and unelevated. Kept because a *change* in that HRESULT is itself evidence. | One function call per second. Negligible. | No |
| **State snapshots** | Full display topology, modes, driver state, registry, per-process GPU adapter, PCIe link. Taken every 15 min so the **last good** can be diffed against the **first bad**. | ~1-2 s every 15 min | No |
| **System counters** | Per-adapter GPU use, DPC and interrupt time, `dwm.exe` CPU, handles, threads, working set. Catches a slow leak in the compositor. | Every 5 s | No |
| **NVIDIA telemetry** | Clocks, pstate, clock *event reasons* (throttling), temperature, power, and **PCIe link gen/width**. A link dropping from gen 4 x8 would be a real finding. | One persistent `nvidia-smi --loop` process | No |
| **ETW trace** | Every present call, flip-queue state, vblank timing, DMA packet, from DxgKrnl and Dwm-Core. The deep view. | On demand, ~20 s | **Yes** |
| **PresentMon** | Per-window presentation mode (`Composed: Flip` vs `Hardware Composed: Independent Flip`) and whether it oscillates. Also gives the frame timing the DWM API refuses to. **Promoted to the primary frame-pacing instrument** because of that failure. | On demand, ~20 s | **Yes** |

Full detail on every metric, including what a suspicious value looks like:
[`docs/METRICS.md`](docs/METRICS.md).

## Resource guarantees

- **Disk capped at 300 MB** (`MaxDataMB` in `config.psd1`). A janitor runs every
  10 minutes and on every capture. Over budget, it deletes oldest-first, ETW
  traces first because they dominate.
- **Anything in `<DataDir>\keep\` is never auto-deleted.** Pin a matched
  good/jitter pair there and it survives.
- **ETW traces are capped at 64 MB each** by `profiles/jitterlab.wprp`. The
  built-in Windows profiles are uncapped and can run to several hundred MB;
  they are only a fallback.
- **CPU cost of continuous sampling is a rounding error**: one API call per
  second and a counter read every five. `nvidia-smi` loops in a single
  persistent process rather than being respawned.
- **Data never goes in a synced folder.** Default `DataDir` is `C:\JitterLab`.
  The kit refuses to run if `DataDir` looks like SynologyDrive, OneDrive,
  Dropbox or Google Drive.

## Quick start

```
.\jitterlab.cmd selftest      # proves the kit works, collects nothing
.\jitterlab.cmd status        # what is running, disk used, live DWM numbers
.\jitterlab.cmd start         # begin continuous sampling
```

When it next judders:

```
.\jitterlab.cmd snapshot jitter
.\jitterlab.cmd trace jitter        (elevated)
.\jitterlab.cmd presentmon jitter   (elevated)
```

Then fix it with **Ctrl+Alt+D** and immediately capture the healthy twin:

```
.\jitterlab.cmd snapshot good
.\jitterlab.cmd trace good          (elevated)
.\jitterlab.cmd presentmon good     (elevated)
.\jitterlab.cmd diff                # last good vs last jitter
```

The matched pair is the whole point: same machine, minutes apart, one variable.

Step-by-step version: [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## Commands

| Command | Elevation | What it does |
|---|---|---|
| `selftest` | no | Parses every script, checks config, exercises the janitor and differ against fakes, probes capabilities. Collects nothing. |
| `status` | no | Kit state, disk usage, sampler/trace state, live DWM numbers. |
| `start` / `stop` | no | Continuous sampler on/off. `-MaxMinutes N` to auto-stop. |
| `snapshot [auto\|good\|jitter]` | no | One full state capture. |
| `diff` | no | Latest good vs latest jitter. `-Good`/`-Bad` for specific files, `-IncludeNoise` to see everything. |
| `trace [label]` | **yes** | ETW capture, default 20 s. |
| `presentmon [label]` | **yes** | PresentMon capture plus a presentation-mode summary. |
| `clean` | no | Run the janitor. `-WhatIfOnly` for a dry run. |
| `pack [out.zip]` | no | Zip the kit for sharing. Excludes `bin\`. |

## What needs UAC

Only `trace` and `presentmon`, because Windows requires elevation for ETW
capture. Everything else (all continuous monitoring, all snapshots, all
diffing) runs as a normal user. See [`docs/ELEVATED-STEPS.md`](docs/ELEVATED-STEPS.md)
for the exact commands, and for the optional elevated setup (a scheduled task
that would let tracing run without a prompt).

## Layout

```
jitter-lab\
  jitterlab.cmd          launcher
  JitterLab.ps1          entry point, all commands
  config.psd1            every tunable: paths, caps, intervals
  Test-JitterLab.ps1     self-test
  lib\
    DwmTiming.ps1        DwmGetCompositionTimingInfo P/Invoke
    Snapshot.ps1         full state capture
    Sampler.ps1          continuous background loop
    Retention.ps1        disk-budget janitor
    Diff.ps1             snapshot comparison, signal vs noise
    Trace.ps1            wpr.exe wrappers (elevated)
    PresentMon.ps1       PresentMon wrapper (elevated)
  profiles\
    jitterlab.wprp       capped 64 MB ETW profile
  docs\
    METRICS.md           every metric, why it matters, what bad looks like
    RUNBOOK.md           what to do when it judders
    ELEVATED-STEPS.md    the UAC-requiring steps, ready to paste
  bin\
    PresentMon.exe       third-party, staged separately, not redistributed
```

## Distribution

`.\jitterlab.cmd pack` produces a zip of code and docs. `bin\` is excluded
deliberately: PresentMon is Intel's binary under its own licence, so point
people at Intel's release rather than redistributing it.

Nothing in the kit hard-codes a path outside itself except `DataDir`, which is
a single config value. It will run on any Windows 10/11 box with a hybrid GPU.

## Honest limitations

- **The one no-admin frame-pacing metric does not work on this machine.**
  `DwmGetCompositionTimingInfo` returns `hr=0x88980090` for a null, desktop or
  shell window handle, unelevated, with the display healthy and the struct size
  verified at 320 bytes. So it is the API declining, not a bug in the kit. The
  practical consequence: **measuring frame pacing requires elevation**, via
  PresentMon or ETW. The call is still made every second, because if that
  HRESULT ever changes (after a reboot, during a jitter, after Ctrl+Alt+D),
  that correlation is worth more than the counters would have been.
- **A cure is not a root cause.** Nothing here explains the 3-5 hour build-up or
  the few seconds of relief from window activity. Those are the two facts any
  real answer must account for.
- **No per-rail voltage telemetry.** Not exposed on this laptop without HP's own
  tooling. GPU power draw, temperature and throttle reasons are all we get.
- **True DPC latency needs a kernel driver.** `% DPC Time` is a proxy. The ETW
  trace is the better instrument if DPCs ever look implicated.
- **Reading an ETL properly needs Windows Performance Analyzer**, a separate
  download. Capture now, analyse later: the ETL is the perishable evidence.
- **The classifier in `Diff.ps1` is a heuristic.** `SIGNAL` and `noise` are my
  judgement about what should not drift. Use `-IncludeNoise` when a diff looks
  suspiciously empty.
