# Laptop + external monitor: the whole desktop stutters after the monitor sleeps — cause found, instant fix

**The "ghost internal display" bug on hybrid-graphics (Intel + NVIDIA) Windows laptops.**

## TL;DR

- **Symptom:** laptop docked with the **lid closed**, external monitor on the NVIDIA GPU. At some point the
  **entire desktop starts stuttering** — dragging windows, scrolling, video, app-drawn cursors — while the
  **normal mouse pointer stays perfectly smooth**. Dragging a window helps for a second or two, then it comes back.
  Restarting `dwm.exe`, `Win+Ctrl+Shift+B`, power-cycling the monitor and closing apps do nothing.
  **Only a reboot fixes it.**
- **Trigger:** the external monitor **turned off or went to sleep and came back** (monitor power button,
  Windows "turn off display after", monitor standby).
- **Cause:** when the external monitor disappears, Windows switches output to the **laptop's own internal panel**
  on the **Intel** GPU — even though the lid is closed. When the external monitor comes back, **Windows never
  switches that internal panel off again**. The dark, invisible panel stays live, and the Desktop Window Manager
  (DWM) stalls on it: fixed-length freezes on a fixed rhythm, roughly **half of all frames never reach the screen**.
- **Instant fix (no reboot, no downloads):** Device Manager → *Display adapters* → **Intel(R) UHD Graphics** →
  **Disable**, wait 3 seconds, **Enable**. Screen blinks for 1–2 s, stutter gone.
  Or use the script / one-key hotkey in [`fix/`](fix/).
- **How sure is this?** Reproduced **on demand** (turn the monitor off and on → stutter). Removing the ghost cures it
  (**4 for 4**). Keeping the Intel GPU disabled **prevents it entirely** (2 for 2). Frame-timing captures of
  broken vs healthy are in [`EVIDENCE.md`](EVIDENCE.md).

---

## Background

After years of chasing this on a laptop I bought — reboots, driver changes, forum threads that went nowhere — this
was finally tracked down with the help of **Claude** (Anthropic's AI), by instrumenting the machine properly instead of
guessing: frame-timing captures of the broken and healthy states taken minutes apart, full display-state snapshots
diffed against each other, and a watcher that timestamped the exact moment the ghost display appeared.

This repo exists to help anyone else living with it, and to give the engineers who can actually fix it
(Microsoft, Intel, NVIDIA, laptop makers) a clean reproduction.

---

## Do you have this bug?

You probably do if **most** of these are true:

- [ ] Windows laptop with **two GPUs** — integrated (Intel UHD/Iris, possibly AMD) and discrete (NVIDIA/AMD).
- [ ] Used **docked / lid closed** with an external monitor.
- [ ] The stutter affects **everything drawn by Windows**, but the **normal mouse pointer stays smooth**.
- [ ] It starts **after being away from the computer**, or after turning the monitor off and on — not at boot.
- [ ] Nothing but a **reboot** fixes it.

**Check for certain** — run this *while* it is stuttering (read-only, no admin, changes nothing):

```powershell
powershell -ExecutionPolicy Bypass -File .\detect\Test-GhostDisplay.ps1
```

`RESULT: GHOST` means the Intel GPU is driving a display that is not on your desktop — the state this repo fixes.
In the healthy state it reports `CLEAN`.

---

## Fix it

### 1. By hand (nothing to download)

1. Right-click Start → **Device Manager** → expand **Display adapters**.
2. Right-click **Intel(R) UHD Graphics** (or Iris Xe) → **Disable device** → confirm.
3. Wait ~3 seconds. The screen may blink.
4. Right-click it again → **Enable device**.

**Only do this if your external monitor runs on the discrete GPU.** If the Intel GPU is driving the monitor you are
looking at, disabling it blacks that monitor out until you re-enable it (Device Manager is still keyboard-usable, or
reboot).

### 2. With the script

From an **elevated** PowerShell (Run as administrator):

```powershell
powershell -ExecutionPolicy Bypass -File .\fix\Fix-GhostDisplay.ps1
```

It refuses to run unless another GPU is already driving a display (so it cannot black you out), re-enables the Intel
adapter even if something fails part-way, changes no settings, and logs to `%ProgramData%\GhostDisplayFix\fix.log`.

### 3. One key, no UAC prompt (recommended if you get this regularly)

Once, from an **elevated** PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\fix\Install-Hotkey.ps1            # default Ctrl+Alt+D
powershell -ExecutionPolicy Bypass -File .\fix\Install-Hotkey.ps1 -Hotkey Ctrl+Alt+G
```

After that, **Ctrl+Alt+D** fixes it: ~3 seconds, a 1–2 second blink, smooth. It uses a Windows scheduled task (on
demand only — it never runs by itself) plus a Start Menu shortcut hotkey. No AutoHotkey or other software. The script
it runs lives in `%ProgramData%\GhostDisplayFix`, locked so only administrators can change it. If the hotkey does
nothing right after installing, sign out and back in once.

Remove everything: `.\fix\Install-Hotkey.ps1 -Uninstall`.

---

## What is actually going on (plain English)

A hybrid laptop has two graphics chips. The internal screen is wired to the **Intel** chip; the external monitor
(here) to the **NVIDIA** chip.

1. You step away. The external monitor goes to sleep (or you switch it off). As far as Windows is concerned, it has
   **disappeared**.
2. Windows does not like having no screen, so it **switches to the laptop's internal panel** — on the Intel chip —
   even though the lid is shut and nobody can see it.
3. You come back. The monitor wakes up and Windows puts your desktop back on it. **But it never switches the internal
   panel off again.** The Intel chip keeps driving a dark, invisible 1920×1080 @ 144 Hz display.
4. The **Desktop Window Manager** — the part of Windows that draws everything you see — is now also tied to that
   ghost display. It keeps **freezing for a fixed length of time on a fixed rhythm** (on the test machine,
   ~60–80 ms freezes every ~120–140 ms), throwing away about half of every frame your apps draw.
5. The mouse pointer is drawn by the monitor hardware itself, not by DWM — which is why **it** stays smooth.

Disabling the Intel adapter destroys that ghost display path. When it is re-enabled, it comes back with **no**
display attached — the healthy state — and DWM runs smoothly again.

---

## What does NOT fix it (all tried, repeatedly)

| Tried | Result |
|---|---|
| Restart `dwm.exe` | No |
| `Win+Ctrl+Shift+B` (graphics driver reset) | No |
| Power-cycle the monitor, replug the cable/dock | No — this is the **trigger**, not the fix |
| Restart `explorer.exe` | No |
| Close background apps (AutoHotkey scripts, a screen-capture app, an always-on-top utility) | No |
| Restart the NVIDIA container services (`NVDisplay.Container`, `NvContainerLocalSystem`) | No |
| UAC / secure-desktop switch, Ctrl+Alt+Del → Cancel, lock + unlock | No |
| `Win+P` | Not a meaningful test with the lid closed: there is only one display to choose from |
| **Disable + re-enable the Intel display adapter** | **Yes, instantly, every time** |
| Reboot / a restart attempt cancelled at the "apps are preventing restart" screen | Yes |

---

## Stopping it from happening at all (optional — each has a trade-off)

- **Keep the external monitor from "disappearing" when it sleeps.** Some monitors cut the DisplayPort link in standby
  (often called *Deep Sleep*, *DP deep sleep* or *Automatic Standby* in the monitor's menu). Turning that off keeps the
  link alive, so Windows never switches to the internal panel. Does not help if you switch the monitor off at the wall
  or with its power button.
- **Stop Windows turning the display off** (Settings → Power → Screen). Removes the most common trigger; costs power.
- **Keep the Intel GPU disabled while docked.** Proven to prevent it completely on the test machine — but the
  **laptop's own screen will not work** until it is re-enabled, and the disabled state **survives reboots**. Undock or
  open the lid without re-enabling it and you get a black laptop screen. Not recommended unless you script the
  re-enable yourself.
- **Automate the fix** (run the hotkey's task whenever the external monitor comes back). Works, but it acts on its own
  and blinks the screen after every monitor wake.

---

## For engineers (Microsoft display / DWM, Intel graphics, NVIDIA, laptop OEMs)

**One-line summary:** on a lid-closed hybrid laptop, when the only external display disappears Windows promotes the
internal panel on the iGPU; when the external display returns, the internal-panel path is not torn down, and DWM
then stalls periodically until that adapter's display path is destroyed.

**Reproduction (100% on the test machine):**

1. Hybrid laptop (Intel iGPU + NVIDIA dGPU), lid closed, one external monitor on a dGPU-wired port. Intel adapter
   healthy: `Win32_VideoController` shows it with **no current mode** (Availability 8 / offline).
2. Power the external monitor off with its button. Wait ~30–90 s.
3. Windows reports the internal panel as the **only** display (e.g. `\\.\DISPLAY20 1920x1080@144`). Intel adapter
   goes **Availability 3 / 1920x1080@144**.
4. Power the monitor back on. The desktop returns to it (`\\.\DISPLAY5 3840x1600@144`).
5. **The Intel adapter stays at Availability 3 / 1920x1080@144** — with the lid shut and only one screen in
   `Screen.AllScreens`. Desktop composition now stutters.
6. `Disable-PnpDevice` on the Intel adapter → the stutter clears at the disable (before the re-enable).
   With the Intel adapter held disabled, steps 2–4 produce a virtual `640x480@64` display instead, dropped cleanly
   on monitor return — **no stutter**.

**Measured (PresentMon 2.5.1, same app and input, broken vs healthy minutes apart):**

| | Stutter (occurred naturally) | Stutter (reproduced) | Healthy |
|---|---|---|---|
| `dwm.exe` frames / 20 s | 1386 | 1380 | 2876 |
| App frames never displayed | 52% | 52% | 0% |
| DWM gaps > 20 ms between displayed frames | 166 | 144 | 0 |
| Stall length / period | 62–70 ms / every 120 ms | 76–83 ms / every 141 ms | — |
| App present interval, median (sd) | 6.94 ms (0.34) | 6.95 ms (4.38) | 6.94 ms (0.39) |
| `dwm.exe` present mode | Hardware: Legacy Flip | Hardware: Legacy Flip | Hardware: Legacy Flip |
| `HybridPresent` | 0 | 0 | 0 |

The application keeps presenting at ~144 fps (median 6.9 ms) in every state. **DWM** is what stalls, with a **fixed stall length on a
fixed period** (1 ms jitter around the period) — the signature of a wait that times out rather than of load. Stall
length differs between occurrences (62.5 vs 76 ms), so it does not look like a single constant timeout. One untested
idea: the two numbers behave like a phase relationship between two display clocks — the external monitor and the
dark internal panel.

**Environment:**

| | |
|---|---|
| Laptop | HP Victus 16 (16-d1xxx), BIOS F.14 |
| CPU / iGPU | Intel Core i7-12700H, Intel UHD Graphics (PCI `8086:4626`), driver **32.0.101.7088** |
| dGPU | NVIDIA GeForce RTX 3060 Laptop GPU 6 GB (PCI `10DE:2520`), driver **581.83** (32.0.15.8183) |
| OS | Windows 10 Pro 22H2, build 19045.7663 |
| External | LG UltraGear 38GN950, 3840×1600 @ 144 Hz, through an HP Thunderbolt Dock G4 on the laptop's USB-C port (no Thunderbolt controller on this laptop, so DP Alt Mode). Wired to the NVIDIA GPU: it stays up with the Intel adapter disabled |
| Internal panel | 1920×1080 @ 144 Hz |
| Settings | HAGS **off** (`HwSchMode=1`), MPO **disabled** (`OverlayTestMode=5`), display-off after 20 min on AC |

**Ruled out by direct measurement during the stutter:** NVIDIA power management (clocks pinned at P0 throughout), VRAM
pressure (1.6 of 6 GB), display mode / link drop (external stays 3840×1600 @ 143), CPU load and DPC storms (DPC
0.00%, interrupt 0.39%), any process rendering on the Intel adapter (none).

**Open questions we could not answer from outside:**

- **Why is the internal-panel path not demoted when the external display returns?** Is this in the Windows display
  topology logic (CCD / DisplayConfig persistence), in the Intel display driver, or in the lid-switch handling?
- **What exactly is DWM waiting on during each stall?** A vblank or flip-completion from the dark internal panel is the
  obvious suspect. A DxgKrnl ETW trace would show it; our `wpr` capture with a custom profile failed
  (`0xC5600611`), so this is unconfirmed.
- Does it affect **Windows 11**, **MPO enabled**, **HAGS on**, **AMD iGPUs**, or **MUX-switch laptops in hybrid mode**?
  Only one configuration has been tested.
- `DwmGetCompositionTimingInfo` returns `0x88980090` on this machine in every state, elevated or not, so DWM's own
  counters could not be used. Is that expected on hybrid systems?

Raw PresentMon CSVs (broken, reproduced, healthy) and the display-event timeline are in [`evidence/`](evidence/).
The diagnostic kit used to capture everything is in [`diagnostics/jitter-lab/`](diagnostics/jitter-lab/).

---

## Scope and honesty

- **Proven on one machine.** The mechanism is general enough that other hybrid laptops are very likely affected, but
  that is an inference. Run the detector before trusting the fix.
- **This is a workaround, not a fix.** The real fix belongs in Windows or the Intel driver. See the engineer section.
- **No driver changes are recommended.** Nothing here points at a specific driver version, and none was changed to
  find it.
- Reports from other machines — especially Windows 11, AMD iGPUs and other brands — are very welcome: open an issue
  with your laptop model, GPUs, driver versions, and the detector output while it is stuttering.

## Related reports

Threads describing what looks like the same problem are listed in [`RELATED.md`](RELATED.md).

## Credits

Diagnosed by the owner of the affected laptop together with **Claude** (Anthropic), September 2026.
Frame timing captured with Intel **PresentMon** ([GameTechDev/PresentMon](https://github.com/GameTechDev/PresentMon)).

## License

MIT — see [`LICENSE`](LICENSE). Use at your own risk; the scripts change device state (briefly) and need admin rights.
