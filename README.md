# Disk Reclaim

**Find what is filling this Mac, and remove only what you choose.**

Disk Reclaim is a free, native macOS app that shows you — down to the exact
block — what is using space on your disk, and lets you reclaim it safely.
Nothing you remove is erased outright: files are moved to the Trash with a
recorded way back, and nothing is touched unless you pick it.

- **No networking, no telemetry, no update check.** What it reads about your
  disk never leaves your Mac.
- **Exact bytes, not estimates.** It counts the blocks each file actually
  occupies, so the sizes you act on are real.
- **A proven way back.** Every removal records how it comes back before
  anything is moved. Anything without a safe way to restore it is left alone.

Requires **macOS 14 (Sonoma) or later** · Apple Silicon & Intel.

---

## Quickstart — build & run from source

The simplest way to run Disk Reclaim without any Gatekeeper prompts. Requires
**Xcode 16+** (or the matching Swift 6 toolchain) on macOS 14+.

```bash
git clone https://github.com/mohankolli9999/MacApps.git
cd MacApps
scripts/bundle.sh release      # builds and assembles DiskReclaim.app
open .build/DiskReclaim.app
```

A locally built app is not quarantined, so macOS opens it without the "Apple
could not verify…" dialog you get from a downloaded, un-notarized build. On
first launch it will ask for **Full Disk Access** (System Settings → Privacy &
Security) so it can measure the whole volume.

No Xcode? Use the downloadable build below instead.

---

## Install

1. Download the latest `DiskReclaim.dmg` from
   [Releases](https://github.com/mohankolli9999/MacApps/releases/latest)
   (or the download page).
2. Open the `.dmg` and drag **Disk Reclaim** into your **Applications** folder.

### First launch (unsigned build)

The current build is **not yet notarized by Apple**, so macOS asks you to
confirm the first time you open it. This is a one-time step:

1. Try to open Disk Reclaim. macOS says it "cannot be checked for malicious
   software" — expected for an app this new.
2. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to Disk Reclaim.
3. Confirm once more. From then on it launches with a normal double-click.

Disk Reclaim also asks for **Full Disk Access** so it can measure the whole
volume. Grant it in **System Settings → Privacy & Security → Full Disk Access**.

---

## Using the app

1. **Scan.** On launch, Disk Reclaim walks your disk and shows a treemap and a
   list of what is using space, largest first.
2. **Inspect.** Each item shows how much space it holds and, where relevant,
   why deleting it may free less than its size (snapshots, caches that expire,
   cloud placeholders).
3. **Select.** Pick what you want to remove. Items with no proven way back are
   marked "Cannot be restored" and are left in place.
4. **Reclaim.** Selected files are moved to the Trash — not erased. Use
   **Put Back** in Finder to undo any of it.

---

## Privacy

Disk Reclaim has no networking code. It never uploads, shares, or reports what
it reads about your disk, and there is no telemetry and no update check. The
only identifier it carries is a build number derived from the source commit,
shown in the standard About panel, so a bug report can be tied to a build.

---

## Build from source

Requires the Swift 6 toolchain (Xcode 16+ or a matching Swift toolchain).

```bash
# Debug build of all targets
swift build

# Build and run the app bundle (release)
scripts/bundle.sh release        # prints the path to DiskReclaim.app
open .build/DiskReclaim.app

# Package a distributable .dmg (also copies it to web/DiskReclaim.dmg)
scripts/dmg.sh release           # prints the path to the .dmg
```

`bundle.sh` assembles the `.app` wrapper SwiftPM does not produce, and
ad-hoc signs it. Developer ID signing and notarization are intentionally kept
out of the script for now — adding them is a localized change when an Apple
Developer Program membership is in place.

### Run the tests

The test suite is a standalone executable, not XCTest:

```bash
swift run ReclaimTests
```

---

## Command-line tool

A `reclaim` CLI mirrors the core engine for scripting and measurement:

```bash
swift run reclaim <command> [paths...]

  scan        measure catalogued artefacts
  plan        measure and validate restore recipes
  reclaim     free space (dry run unless --confirm)
  restore     show restore commands for what was freed
  walk        time a full volume walk (default: home)
```

`reclaim` is a **dry run by default** — it only frees space when you pass
`--confirm`.

---

## Project layout

| Path | What it is |
|------|-----------|
| `Sources/ReclaimCore` | Volume scanning, catalogue, restore recipes, Trash |
| `Sources/DiskReclaim` | SwiftUI app |
| `Sources/reclaim` | Command-line tool |
| `Sources/ReclaimTests` | Test harness (`swift run ReclaimTests`) |
| `scripts/bundle.sh` | Assemble and sign `DiskReclaim.app` |
| `scripts/dmg.sh` | Package the app into a `.dmg` |
| `web/` | Static download page (deployable to Vercel) |

---

## License

Disk Reclaim is free.
