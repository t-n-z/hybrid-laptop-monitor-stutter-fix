# Evidence

Everything behind the claims in the README, in the order it was established. All captures come from one machine
(environment in the README). Times are local, 24-hour, all on the same day.

Evidence standard used throughout: **only a positive result counts.** A remedy that "did nothing" was never treated as
ruling a suspect out if the conditions made that negative meaningless.

---

## 1. The state difference: a ghost display on the Intel adapter

Full read-only state snapshots (display adapters, modes, desktop screens, monitors, DWM and graphics-driver registry,
services, per-process GPU adapter) were taken during the stutter and after the fix, then diffed.
**The only meaningful difference:**

| Snapshot | State | Intel UHD Graphics | NVIDIA RTX 3060 (external) | Desktop screens |
|---|---|---|---|---|
| 16:41, 16:42, 16:57 | stutter | **Availability 3 (running), 1920x1080 @ 144** | 3840x1600 @ 143 | 1 (3840x1600) |
| 17:08, 17:12+ | healthy | **Availability 8 (offline), no mode** | 3840x1600 @ 143 | 1 (3840x1600) |

1920x1080 @ 144 Hz is the laptop's internal panel. The lid was closed throughout.
Same monitors, same screens, same registry values, same services in both states.

---

## 2. The trigger: the external monitor going away

A display-change logger (running for other reasons) had recorded the day. Both natural stutter episodes followed the
external monitor disappearing and Windows falling back to the internal panel:

```
02:27:54  internal panel becomes the ONLY display   [DISPLAY1  1920x1080@144]   external monitor gone
04:17:25  external monitor back                     [DISPLAY5  3840x1600@144]
04:18     stutter noticed
-------
12:09:21  internal panel becomes the ONLY display   [DISPLAY15 1920x1080@144]   external monitor gone
12:09:36  external monitor back                     [DISPLAY5  3840x1600@144]
12:09:42  laptop sleeps; resumes 16:36
16:41     stutter noticed
```

One further episode (07:15) has no logged trigger. The logger records the state after a change, so a brief drop could
be missed. Unconfirmed.

---

## 3. Reproduced on demand

Machine healthy; Intel adapter offline for the previous 42 minutes (sampled every 30 s). The external monitor was
switched off with its power button for ~1.5 minutes, then back on. **The stutter returned, first attempt.**

```
17:12:28 -> 17:54:42   Intel adapter OFFLINE (8/none)                 healthy baseline, 30 s samples
17:55:14               Intel adapter LIVE (3 / 1920x1080@144)         monitor switched off
17:55:18               internal panel is the ONLY display [DISPLAY20 1920x1080@144]
17:55:20               watcher: "DISPLAY STATE CHANGE intel 8/none -> 3/1920x1080@144"
17:56:38               external monitor back on [DISPLAY5 3840x1600@144]
17:56:55 -> 17:57:28   Intel adapter STILL LIVE (3 / 1920x1080@144)   the ghost persists
~17:57                 stutter confirmed by the user
```

Raw sample stream: [`evidence/display-state-reproduction.csv`](evidence/display-state-reproduction.csv).

---

## 4. Frame timing: what the stutter actually is

Intel PresentMon 2.5.1, `--track_hybrid_present`, 20 s each, the same window being dragged the same way each time.
Raw CSVs in [`evidence/presentmon/`](evidence/presentmon/); computed figures in
[`evidence/presentmon/SUMMARY.txt`](evidence/presentmon/SUMMARY.txt).

| | 1. Stutter, natural | 2. Stutter, reproduced | 3. Healthy after fix |
|---|---|---|---|
| `dwm.exe` frames | **1386** | **1380** | **2876** |
| `dwm.exe` display gap median / p95 / max (ms) | 6.95 / 62.56 / 69.57 | 6.95 / 76.40 / 118.07 | 6.94 / 6.99 / 7.56 |
| DWM gaps > 20 ms | 166 | 144 | **0** |
| Stall lengths (most common) | 69 ms x61, 62 x55, 63 x44 | 76 ms x100, 83 x19, 69 x13 | none |
| Stall period median (p5-p95) | 120.1 ms (118.9-121.8) | 141.1 ms (135.1-144.4) | none |
| App frames presented | 2876 | 2813 | 2875 |
| App present interval median (sd) | 6.94 ms (0.34) | 6.95 ms (4.38) | 6.94 ms (0.39) |
| **App frames never displayed** | **1492 (52%)** | **1456 (52%)** | **1 (0%)** |
| `HybridPresent` | 0 | 0 | 0 |

Reading it:

- The app presents at ~144 fps in every state. The problem is downstream of the app.
- In the broken state DWM composes normally for a while, then **stalls for a fixed length**, on a **fixed period**
  with ~1 ms of wobble. That regularity is the signature of a wait that times out, not of contention.
- The long gaps are the stall length plus one refresh (e.g. 76 + 7 = 83 ms).
- Stall length and period differ between occurrences (62.5/120 ms vs 76/141 ms), so it is not one constant timeout.
  In both, DWM is stalled roughly half the time and about half of all app frames are lost.
- Healthy: no DWM gap longer than 7.56 ms at 144 Hz.
- An earlier reading that the 62.5 ms stall was "exactly four 15.625 ms timer ticks" was **withdrawn** once the
  reproduced stall measured 76 ms (4.89 ticks). Timer resolution was 1.0 ms when checked in the healthy state.

---

## 5. Causation, by intervention in both directions

| Intervention | Result |
|---|---|
| Ghost present | Stutter. Observed in 2 natural episodes (Intel adapter checked during them) plus 1 reproduced; in the third natural episode the adapter was not checked |
| **Remove** the ghost: disable + re-enable the Intel adapter | **Cured, 4 for 4.** The stutter clears at the *disable*, before the re-enable: the screen blanks for 1-2 s while the adapter stays disabled for longer. |
| **Prevent** the ghost: hold the Intel adapter disabled, then switch the monitor off and on twice | **No stutter, 2 for 2.** Windows created a virtual `640x480@64` display while the monitor was off and dropped it cleanly on return. The Intel adapter stayed offline throughout. |

The ghost path is necessary for the stutter, and removing it is sufficient to end it. Whether it causes DWM's stall
*directly*, or is the visible part of a deeper topology state created at the same moment, cannot be separated from
outside Windows. For a workaround the distinction does not matter.

---

## 6. Ruled out by direct measurement during the stutter

| Suspect | Measurement |
|---|---|
| NVIDIA power management | Clocks pinned at P0, 1425/7001 MHz, through the stutter and the smooth moments |
| VRAM pressure | 1.6 GB of 6 GB |
| External display mode / link | 3840x1600 @ 143 on the NVIDIA adapter throughout |
| CPU load / DPC storm | CPU idle; DPC 0.00%, interrupt 0.39% |
| A process rendering on the Intel adapter | None (GPU engine counters by adapter) |

## 7. Tried and did not help

Restarting `dwm.exe`, `Win+Ctrl+Shift+B`, monitor power-cycle / replug, restarting `explorer.exe`, closing background
apps, restarting both NVIDIA container services, UAC / secure-desktop switches, Ctrl+Alt+Del then Cancel, lock + screen
off. **Why none of them work:** none of them touch the Intel adapter's display path.

## 8. Instruments that failed (for anyone repeating this)

- `DwmGetCompositionTimingInfo` returns `0x88980090` on this machine in every state, elevated or not, with a correct
  struct size (320 bytes). DWM's own counters were therefore unavailable.
- `wpr` failed to start with a custom 64 MB profile (exit `0xC5600611`), although the profile parses. No ETW trace was
  captured. PresentMon covered the need.
