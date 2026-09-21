@{
    # ---------------------------------------------------------------------
    # JitterLab configuration. Edit values here; no script changes needed.
    # ---------------------------------------------------------------------

    # Where captured data is written. MUST NOT be inside a synced folder
    # (SynologyDrive / OneDrive / Dropbox): traces are large and would sync.
    # Created on first run. No admin rights needed for a folder under C:\.
    DataDir = 'C:\JitterLab'

    # Hard disk budget for DataDir, in megabytes. The janitor deletes the
    # oldest unpinned files whenever the total exceeds this.
    # Anything in DataDir\keep\ is pinned and never auto-deleted.
    MaxDataMB = 300

    # Warn (do not delete) once usage passes this fraction of MaxDataMB.
    WarnAtFraction = 0.75

    # --- sampler intervals, seconds. Higher = lower overhead. --------------
    DwmTimingIntervalSec  = 1     # DwmGetCompositionTimingInfo. Very cheap.
    CounterIntervalSec    = 5     # perf counters (GPU engine, DPC, dwm cpu)
    NvidiaIntervalSec     = 10    # nvidia-smi, runs as one persistent process
    SnapshotIntervalMin   = 15    # full state snapshot for good-vs-bad diffing
    # Per-adapter display state (availability + mode). Added 2026-09-21 after
    # the ghost-panel finding: during the jitter the Intel adapter holds a live
    # 1920x1080@144 mode with the lid shut; healthy, it is Offline. This stream
    # timestamps the moment it flips, which is the trigger we still need.
    DisplayIntervalSec    = 30

    # Rotate the sampler CSVs when they pass this size, in megabytes.
    RotateCsvAtMB = 8

    # Keep at most this many rotated CSVs per stream before the janitor
    # starts removing the oldest.
    KeepRotatedCsv = 12

    # Keep at most this many full snapshots. At 15 min apart, 200 is ~50 h.
    KeepSnapshots = 200

    # --- ETW tracing (needs elevation) -------------------------------------
    # Custom profile keeps buffers small; built-in profiles are the fallback.
    WprProfile      = 'profiles\jitterlab.wprp!JitterLab.Light'
    WprFallback     = @('DesktopComposition', 'GPU')
    TraceSeconds    = 20
    # ETLs are the big files and dominate the budget. 3 x 64 MB = 192 MB,
    # which leaves headroom inside MaxDataMB for CSVs and snapshots.
    MaxTraceCount   = 3

    # --- PresentMon (stage 3) ---------------------------------------------
    PresentMonExe      = 'bin\PresentMon.exe'
    PresentMonSeconds  = 20
}
