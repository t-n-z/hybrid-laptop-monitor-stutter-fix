PresentMon is NOT included in this repository (it is Intel's binary, under
Intel's licence). Download the standalone console build and put it here:

  https://github.com/GameTechDev/PresentMon/releases

  Tested with: PresentMon-2.5.1-x64.exe (v2.5.1, 956,768 bytes,
  SHA-256 9bec3083069f58f911e6a512f4806db51a27bd096103087bc1d05ef54c80a191)

lib\PresentMon.ps1 finds any PresentMon*.exe in this folder. It needs an
elevated prompt to trace other processes. Flags were verified against 2.5.1;
if a different version exits with an error, run it with --help and compare
against the flags in lib\PresentMon.ps1.
