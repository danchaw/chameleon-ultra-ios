# Move the whole ChameleonUltra-iOS project into the DSH workspace.

## Current state (as of 2026-10-28 19:50 +08:00)

The project had been living under ZCode's workspace:
`C:\Users\yangb\.zcode\workspace\draft-079c83c4-7ade-47ee-98ee-7fc895ad23c8`
and the user asked to relocate **everything** to the DSH workspace and do all
future work there.

Source tree that was moved (188.9 MB total, git tree clean, HEAD = 83d1dc0):

- `ChameleonUltra-iOS/` — the SwiftUI rewrite (Xcode project, `.github/workflows/build-ipa.yml`, SharedKit package)
- `ChameleonUltraGUI/` — the original Flutter reference app
- `ChameleonUltra-GF.ipa` — geofence branch build
- `ChameleonUltra.ipa` — main branch build
- `poll-build-1230.sh` — CI poll-and-ship helper script

## How it was done

`robocopy <src> <dst> /E /MOVE /NFL /NDL /NJH /NJS /NP` — copy first, delete
source only after the copy is verified (robocopy exit code 1 = "files copied",
which is success). The old folder itself could not be removed afterwards
because a shell process still holds a handle; it was verified empty (0 entries)
and can be deleted after a reboot.

## Post-move fixes

1. `git -C <new>/ChameleonUltra-iOS status` → clean, branch
   `feature/geofence-autopoll`, remote `https://github.com/danchaw/chameleon-ultra-ios.git`.
   No stale `.git/*.lock` files.
2. `poll-build-1230.sh` had a hard-coded `WS="C:/Users/yangb/.zcode/workspace/Documents/DSH"`.
   **Lesson:** a bare string replace of `draft-079c83c4-…` produced a bogus
   path because the script's WS line used forward slashes. Fix by replacing the
   whole literal: `WS="C:/Users/yangb/Documents/DSH"`.
3. **Both .ipa files were 1.30.9** — the branch run's ship step had written the
   branch build over `ChameleonUltra.ipa` and the scripted restore of main was
   skipped by the Ctrl-C / path confusion. Restored:
   - main 1.29.0 from run 91 (`a99505c`) artifact id `12743341636`
   - branch 1.30.9 (59) was already correct
4. `.gh_token.tmp` (GitHub token pulled from the git credential helper with
   `git credential fill`, password line only) did not survive the move; it was
   re-fetched. **Never echo it into logs.**
5. `git push` and the workflow `dispatches` (build-ipa.yml, `ref: main`) need
   the token; dispatch returns HTTP 204.
6. Run 108 was dispatched **directly on `main`** so a main-branch artifact
   exists from now on instead of requiring a fragile "restore from some other
   run" step.

## Inspecting an .ipa on Windows

`Expand-Archive` refuses `.ipa` — copy to `.ipa.zip` first. Info.plist inside is
a **binary** plist, so the version is found with a regex over the raw text:
`[regex]::Matches($text, '[0-9]+\.[0-9]+\.[0-9]+')`.

## Rules learned

- Read-modify-write of Swift sources MUST preserve UTF-8: use
  `[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))`.
  A `Get-Content`/`Set-Content` round trip here mangles Chinese strings into mojibake.
- `project.pbxproj` uses `PBXFileSystemSynchronizedRootGroup`, so new `.swift`
  files placed in `ChameleonUltra/` are picked up automatically — no manual
  PBXBuildFile/PBXFileReference edits.
- The workflow's L10n guard greps `^\s+"key":` with a **case-sensitive**
  pattern, so `"Delete"` and `"delete"` are a legitimate pair.
- There is no Python on this machine (`python` → Store alias); do quick text
  checks in PowerShell instead.

## Where things stand

Next: v1.31 — geofence map redesign (free drag/zoom, place search via
MKLocalSearchCompleter, tap-to-place crosshair, then radius). New file
`ChameleonUltra/FenceLocationPicker.swift`, editor rewritten in
`ChameleonUltra/GeoRegionsView.swift`.