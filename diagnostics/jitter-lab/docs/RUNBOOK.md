# Runbook: capturing evidence when the stutter happens

You only need this if you want to **measure** the problem (for example to add your machine's data to the issue
tracker, or to check whether you have the same bug). To just **fix** it, use `../../../fix/`.

The value of this kit is the **matched pair**: the same machine captured while broken, and again a minute later while
healthy, with one variable changed between them.

---

## Before anything: start the sampler

```
.\jitterlab.cmd status
.\jitterlab.cmd start
```

It costs almost nothing (one API call per second, a counter read every 5 s, one persistent `nvidia-smi` logger) and it
is the only thing that captures the *moment the ghost display appears*: it logs `DISPLAY STATE CHANGE` and takes a
snapshot as soon as the Intel adapter goes live. Disk is capped at 300 MB, self-clearing.

---

## When the stutter starts

### 1. Capture the broken state (no admin, ~5 s)

```
.\jitterlab.cmd snapshot jitter
```

### 2. Frame timing (admin, ~20 s)

From an elevated PowerShell (see `ELEVATED-STEPS.md`):

```
.\jitterlab.cmd presentmon jitter
```

**Drag a window around and scroll the whole time it runs.** An idle desktop produces a capture of nothing.

### 3. Fix it

Run the fix from `../../../fix/` (or your hotkey). Expect a 1-2 second blink.

### 4. Capture the healthy twin immediately

Within a minute or two, doing the **same** dragging as in step 2:

```
.\jitterlab.cmd snapshot good
.\jitterlab.cmd presentmon good      (elevated)
```

### 5. Diff

```
.\jitterlab.cmd diff
```

Latest good against latest jitter, SIGNAL rows first. On the affected machine the SIGNAL rows were exactly the Intel
adapter's `Availability` (3 -> 8) and its mode (1920x1080@144 -> none). If SIGNAL is empty, re-run with
`-IncludeNoise` before concluding nothing changed.

### 6. Pin the pair so the janitor cannot delete it

```
mkdir C:\JitterLab\keep\my-pair
copy C:\JitterLab\snapshots\snap-*-jitter.json  C:\JitterLab\keep\my-pair\
copy C:\JitterLab\snapshots\snap-*-good.json    C:\JitterLab\keep\my-pair\
copy C:\JitterLab\presentmon\pm-*.csv            C:\JitterLab\keep\my-pair\
```

Nothing under `keep\` is ever auto-deleted.

---

## Reproducing it on purpose

With the machine healthy and the sampler running, switch the external monitor **off** with its power button, wait
30-90 seconds, switch it back **on**. On the affected machine this reproduced the stutter on the first attempt. Watch
`C:\JitterLab\sampler.log` for `DISPLAY STATE CHANGE` and `C:\JitterLab\live\display-*.csv`.

**Before sharing snapshots:** they contain your process list and full `nvidia-smi -q` output (which includes the GPU
serial number and UUID). Share the PresentMon CSVs and the diff output instead, or redact first.

---

## Housekeeping

```
.\jitterlab.cmd status            # disk usage and state
.\jitterlab.cmd clean -WhatIfOnly # what the janitor would remove
.\jitterlab.cmd stop              # stop the sampler
```

The sampler does not survive a reboot or sign-out. Restart it with `.\jitterlab.cmd start`.
