# accel/tools/fastbuild — FASTBuild binaries (not committed)

`FBuild.exe` is a vendor binary, so it's **gitignored**, not checked into this
public repo (same policy as the P4Python wheels under `perforce/tools/`).
Re-fetch it:

1. Download the Windows x64 zip from
   <https://www.fastbuild.org/docs/download.html> (this repo's results used
   **v1.20**):
   `https://www.fastbuild.org/downloads/v1.20/FASTBuild-Windows-x64-v1.20.zip`
2. Extract `FBuild.exe` (+ `FBuildWorker.exe`, `LICENSE.TXT`) into this dir.
3. Verify: `.\FBuild.exe -version` → `FASTBuild v1.20 - ...`

`../../scripts/demo-fbuild.ps1` expects `FBuild.exe` here and will point you at
these steps if it's missing.

FASTBuild is MIT-licensed (Franta Fulin); see `LICENSE.TXT` in the zip.
