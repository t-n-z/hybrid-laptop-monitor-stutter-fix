# Related reports

Threads and write-ups describing external-monitor or desktop stutter on laptops that **may** be the same problem.
Symptom overlap only: none of these has been confirmed to be the ghost-internal-display bug. If you are affected, the
quickest check is [`detect/Test-GhostDisplay.ps1`](detect/Test-GhostDisplay.ps1) while it is stuttering.

This list is being extended. Know of another thread? Open an issue or a pull request.

## Hybrid / Optimus laptops with an external display

- Intel Community: [Request solution to HDMI external display lag on Optimus laptops](https://community.intel.com/t5/Graphics/Request-Solution-to-hdmi-external-display-lag-on-Optimus-laptops/td-p/655512)
- Lenovo Forums: [Apps using the iGPU stutter when the dGPU is active using Advanced Optimus](https://forums.lenovo.com/t5/Gaming-Laptops/Apps-using-the-iGPU-stutter-when-the-dGPU-is-active-using-advanced-optimus/m-p/5225157)
- Notebookcheck: [Lenovo resolves ThinkPad P1 and X1 Extreme second-screen low framerate bug](https://www.notebookcheck.net/Lenovo-resolves-ThinkPad-P1-and-X1-Extreme-s-second-screen-low-framerate-bug-then-pulls-the-update-that-fixes-it.447060.0.html)
- Microsoft Q&A: [External monitor stutter](https://learn.microsoft.com/en-us/answers/questions/3268366/external-monitor-stutter)
- Microsoft Q&A: [External monitor stuttering](https://learn.microsoft.com/en-us/answers/questions/3903230/external-monitor-stuttering)
- Framework Community: [Stuttering cursor in Windows desktop on external displays](https://community.frame.work/t/stuttering-cursor-in-windows-desktop-on-external-displays/45645)

## Desktop Window Manager stutter that only a reboot fixes

- Microsoft Q&A: [Windows DWM issue](https://learn.microsoft.com/en-us/answers/questions/5560590/windows-dwm-issue)
  (Windows 11, RTX 40-series; stutter after exiting full-screen games, only a reboot clears it)
- microsoft/terminal: [No longer uses Hardware Composed: Independent Flip after 24H2](https://github.com/microsoft/terminal/discussions/19050)
- [DWM stutter and lag on Chromium-based apps](https://mr-kayz.github.io/RTS-Extra-Docs/docs/issues/DWM-lag-on-Chromium-bug.html)
  and [Fix Windows 11 24H2 rendering and freezing issues in Chromium apps](https://schalkburger.dev/posts/fix-windows-chromium-freezing)
  (a different DWM presentation-mode issue on Windows 11 24H2+, with a similar feel)
