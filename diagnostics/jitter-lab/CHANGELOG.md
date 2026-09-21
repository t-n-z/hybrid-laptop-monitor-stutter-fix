# Changelog — JitterLab

## 1.1.0 - 2026-09-21 (first live use)

First real jitter captured. The kit found the mechanism: see `../../EVIDENCE.md`.

### Added
- **`display-*.csv` stream** (every 30 s, `DisplayIntervalSec`): per-adapter availability and mode. Logs
  `DISPLAY STATE CHANGE` to `sampler.log` and takes a snapshot the moment the Intel adapter flips. Added because the
  jitter state turned out to be the Intel adapter holding a live 1920x1080@144 mode with the lid shut - not a desktop
  monitor, so nothing else in the kit could see it.

### Fixed (every one of these was found by real use, not the self-test)
- **Sampler never launched** from the kit's own path: PS 5.1 `Start-Process -ArgumentList` does not quote array items
  containing spaces, and the kit's install path contained spaces. Paths are now quoted explicitly.
- **ETW start threw immediately**: under `ErrorActionPreference=Stop`, anything `wpr.exe` writes to stderr becomes a
  terminating error. Native calls now run with `Continue` scoped to their function.
- **PresentMon exited 1**: `--no_top` is a 1.x flag; 2.x rejects it. Now `--no_console_stats`, plus
  `--track_hybrid_present`. Flags verified against PresentMon 2.5.1 `--help`.
- **`$args` used as a variable name** in `Trace.ps1` and `PresentMon.ps1` - an automatic variable, same class of trap
  as `$pid`. Renamed.
- **Differ crashed on the first real diff**: a Mandatory parameter rejects null array items. Now `[AllowNull()]`.
- **`stop` waited a fixed 3 s**, too short for a pass that includes a GPU-engine counter read, and a force-kill skipped
  the sampler's `finally`, orphaning its `nvidia-smi` logger. `stop` now polls for up to 20 s and cleans up any logger
  writing into `DataDir`.

### Still open
- **ETW capture fails** with `wpr` exit `0xC5600611` using `profiles\jitterlab.wprp`, although `wpr -profiles` parses
  the file fine. PresentMon covered the need; fallback to the built-in profiles is untested.
- **`DwmGetCompositionTimingInfo`** fails (`0x88980090`) during a jitter and when elevated too. Closed as "does not work
  on this machine".

## 1.0.0 — 2026-09-21

First build. **Staged only: nothing has been run, no watcher is active, no
scheduled task created, `C:\JitterLab` not yet created.**

Built in response to: *"prepare at all angles a set of watchers I can either
turn on by request, when it jitters, or if it's important to be on
indefinitely... must not burden my PC resources or disk... hundreds of MB tops
but start self clearing if it's more than that... cleanly distributable."*

### Included

- **DWM composition timing** via a `DwmGetCompositionTimingInfo` P/Invoke —
  missed, dropped and late frames, compose rate vs refresh rate. Chosen as the
  headline metric because the symptom (composited content judders, hardware
  cursor does not) is the definition of a compositor missing vertical blanks.
  One function call per second; no admin.
- **State snapshots** every 15 minutes for good-vs-bad diffing: display modes
  and topology, `GraphicsDrivers\Configuration` sets, DWM registry, per-process
  GPU adapter LUID, PnP device status, `dwm.exe` handle/thread/working-set
  growth, services, process inventory, NVIDIA telemetry.
- **Continuous sampler** — per-adapter GPU use, DPC and interrupt time, `dwm.exe`
  resources, memory; NVIDIA clocks, throttle reasons and PCIe link gen/width via
  a single persistent `nvidia-smi --loop` process rather than repeated spawns.
- **Snapshot differ** classifying changes as SIGNAL (should not drift during a
  session) or noise (counters, timestamps, utilisation).
- **ETW tracing** through the in-box `wpr.exe`, with a custom profile capping
  buffers at 64 MB. Elevation required by Windows.
- **PresentMon wrapper** plus a presentation-mode summariser, to test the
  composed-flip/independent-flip oscillation theory. Elevation required.
- **Disk janitor**: 300 MB budget, runs every 10 minutes and after every
  capture. Deletes oldest-first, ETW traces first. `keep\` is never touched.
- **Self-test** that parses every script, validates config and the WPR profile,
  exercises the janitor and differ against fakes, and probes capabilities —
  without collecting anything or touching `DataDir`.

### Deliberate decisions

- **Data goes to `C:\JitterLab`, not the kit folder.** If the kit lives in a
  synced folder, captures would sync continuously. The kit refuses to run if
  `DataDir` looks like a synced path.
- **`bin\` is excluded from `pack`.** PresentMon is Intel's binary under its own
  licence; point people at the upstream release.
- **The elevated scheduled task for tracing is documented but NOT created.** It
  would mean an always-available admin task running a script from a synced
  folder. The trade-off is written up in `docs/ELEVATED-STEPS.md`; it needs an
  explicit decision, not a default.
- **`% DPC Time` kept despite being disconfirmed** (0.00% during a jitter on
  2026-09-21). Cheap, and a negative that stays negative is still worth having.

### Found while building (the self-test earned its keep)

- **`DwmGetCompositionTimingInfo` does not work on the test laptop.** Returns
  `hr=0x88980090` with a null, desktop or shell window handle, unelevated, with
  the display healthy. `Marshal.SizeOf` on the struct is 320 bytes and the
  value round-trips, so it is not a marshalling fault. This was meant to be the
  headline no-admin metric; the README and METRICS now say plainly that it
  fails here and that **frame pacing therefore requires elevation** via
  PresentMon or ETW. The call is still made every second so that a *change* in
  that HRESULT is captured — if it starts answering after a reboot, during a
  jitter, or after Ctrl+Alt+D, that correlation beats the counters.
  **Untested:** whether it succeeds in an elevated process. One probe on the
  next elevated pass would settle it.
- **`Add-Type -UsingNamespace System.Runtime.InteropServices` is an error, not a
  warning**, because `-MemberDefinition` already emits that using directive and
  the compiler runs with warnings-as-errors. Removed.
- **`$pid` is a read-only PowerShell automatic variable** — the snapshot
  collector assigned to it and would have thrown at runtime. Renamed.
- **`MaxTraceCount` lowered from 6 to 3.** The self-test caught that 6 x 64 MB
  exceeded the 300 MB budget, so traces would have been deleted almost as fast
  as they were captured.

### Known gaps

- No per-rail voltage telemetry — not exposed on this laptop without HP tooling.
- True DPC/ISR latency needs a kernel driver; `% DPC Time` is a proxy.
- Reading an ETL needs Windows Performance Analyzer (Windows ADK), not installed.
- The SIGNAL/noise classifier in `Diff.ps1` is a heuristic. Use `-IncludeNoise`
  when a diff looks suspiciously empty.
- PresentMon flag names vary between major versions; `docs/ELEVATED-STEPS.md`
  says how to check.
