# claude-native-titlebar

Native Windows title bar for Claude Desktop (MSIX build). Replaces Claude's own
window buttons with the standard Windows frame and moves the toolbar buttons
to the right edge.

## Usage

Quit Claude (including the tray icon), then:

```powershell
powershell -ExecutionPolicy Bypass -File .\claude-native-titlebar.ps1
```

- `-Rollback`: restore the original files
- `-DryRun`: build the patched files into `%TEMP%` without touching the install
- `-PackageDir <dir>`: patch another copy of the package (the folder with
  `app\claude.exe`) instead of the installed one

Run it again after every Claude update.

## How it works

Patches `resources\app.asar` to disable the custom title bar and inject a CSS
fix for the toolbar. It also updates the asar hash in `claude.exe` so Electron's
integrity check passes. The originals are kept as `*.bak`.

## Caveats

- `claude.exe` loses its signature. If Claude won't start, run `-Rollback` or
  reinstall.
- If an update changes the code, the script stops and changes nothing.
- Unofficial. Use at your own risk.
