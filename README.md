# Doppio

A safe duplicate photo/video finder for macOS. Doppio finds files whose contents are
**100% identical** and helps you reclaim disk space without ever risking a unique file.
Safety beats speed and convenience everywhere.

> **Status: Phase 1** — scanning engine (`DoppioCore`) and the read-only `doppio audit`
> command. Trashing (`clean`), `restore` and the SwiftUI app come in the next phases.

## Requirements

- macOS 14 or later
- Swift 6 toolchain: the Xcode **Command Line Tools** are enough (`xcode-select --install`).
  Full Xcode is not required.

## Build, test, install

```sh
make build          # debug build → .build/debug/doppio
make test           # full test suite (Swift Testing)
make install-cli    # release build → ~/.local/bin/doppio  (PREFIX=/usr/local to change)
```

`make test` adds a compiler flag that the Command Line Tools need to find Swift Testing's
macro plugin; with full Xcode, plain `swift test` works too.

## Usage

### Audit (read-only)

```sh
doppio audit ~/Pictures/Export /Volumes/Backup/Phone
doppio audit /Volumes/HDD/Photos --jobs 1             # spinning disk: keep 1 (the default)
doppio audit ~/Downloads --all-types                  # every file type, not just photos/videos
doppio audit /Volumes/Samsung/Dump --random-names-are-copies  # see "Automatic suggestions"
doppio audit ~/Pictures --report ~/Desktop/audit.json # writes audit.json + audit.csv
doppio audit ~/Pictures --report ~/Desktop/reports    # folder (created if needed)
```

Example output (illustrative numbers):

```
Doppio audit (read-only, nothing was modified)

Scanned 1 folder(s): 48210 photos/videos considered in 412.7 s
Duplicate groups:     1873  (1702 auto-resolvable, 171 need your choice)
Redundant copies:     2210 files, 38.4 GB
Reclaimable space:    37.9 GB
  of which automatic: 1950 files, 33.1 GB
Skipped:
  12 symlinks (not followed)
  3110 metadata files (._*, .DS_Store)
  1 packages/bundles (e.g. Photos libraries)
Problems (2, never treated as unique or duplicate):
  2 unreadable file

Report:
  ~/Library/Logs/Doppio/Reports/doppio-audit-20261016-224348.json
  ~/Library/Logs/Doppio/Reports/doppio-audit-20261016-224348.csv
```

Press **Ctrl-C** at any time: the scan stops cleanly and no report is written.

### The report

Both files list every duplicate group with its SHA-256, size, and every file's path,
creation and modification dates and hard-link count.

- **CSV**: one row per file. `suggestion` is `keep` / `trash` for automatic groups and
  `review` for ambiguous ones; `suggested_keep` is the path to keep or `ambiguous`.
- **JSON**: also includes the summary, skip counts, every problem file, inode numbers and
  APFS private sizes.

Reports go to `~/Library/Logs/Doppio/Reports/` by default. Doppio refuses to write a
report inside a folder being scanned.

## How duplicates are found

Names are **never** used to decide whether two files are duplicates. The pipeline:

1. **Walk** the folders recursively with `lstat` (symlinks are never followed; mount points
   inside a folder are not entered — pass other volumes explicitly).
2. **Group by exact size**; drop singletons and zero-byte files.
3. **Quick check**: SHA-256 of the first + last 64 KB (skipped for files ≤ 128 KB).
4. **Full SHA-256** (CryptoKit) of the remaining candidates.
5. **Byte-by-byte comparison** of each candidate against the group's reference file.
   A hash match alone never makes a duplicate.

Then:

- **Hard links** (same device + inode) are one file, not duplicates: listed once, counted
  once, never offered for the Trash.
- **APFS clones** (e.g. Finder's *Duplicate*) share storage. Doppio reads each file's
  private size (`ATTR_CMNEXT_PRIVATESIZE`) so "reclaimable" reflects what would really
  be freed. If that isn't available on an APFS volume, the figure is shown as "up to".
- **Media only by default**: files whose extension conforms to `UTType.image` or
  `UTType.movie` (JPEG, HEIC, PNG, DNG and other RAW, MP4, MOV, …). `--all-types`
  considers everything.

### Always skipped

- AppleDouble files (`._*`) and `.DS_Store`
- `.Trashes`, `.Trash`, `.Spotlight-V100`, `.fseventsd`, `.TemporaryItems`,
  `.DocumentRevisions-V100`
- The contents of packages and bundles — **Photos libraries** (`.photoslibrary`), app
  bundles, etc. Doppio also refuses to scan a folder that is, or is inside, a package.
- iCloud placeholders not downloaded to this Mac (reported; never downloaded by Doppio)

Hidden files are included, so hidden copies like `.Screenshot … .png` are found.

## Automatic suggestions

For each group Doppio looks for the obvious original. A file is a **derived copy** if
removing copy markers from its name gives the name of *another* file in the same group:

| Marker | Example |
|---|---|
| `_N`, `-N` (1–3 digits) | `VID_20250822_205114_1.mp4`, `IMG_1234-1.jpg` |
| ` (N)` | `IMG_1234 (1).jpg` |
| ` N` (Finder) | `sunset 2.heic` |
| ` copy`, ` copy N` | `photo copy.jpg`, `photo copy 2.jpg` |
| ` - Copy`, ` - Copy (N)` | `photo - Copy.jpg` |
| ` - Copia`, ` copia`, ` copia N` | `foto - Copia.jpg`, `foto copia 2.jpg` |
| `Copy of `, `Copia di ` | `Copy of beach.png`, `Copia di mare.png` |
| leading dot | `.Screenshot 2025-01-01 at 10.00.00.png` |
| `_` + epoch-milliseconds (13 digits, 2017–2033) | `IMG_20221001_152443_1706717647603.jpg` |
| `-` + epoch-seconds + `-` prefix (Android trash) | `-1764628937-IMG_20221001_152443.jpg` |
| `.trashed-` + epoch-seconds + `-` prefix | `.trashed-1764628937-IMG_1234.jpg` |
| `_.` prefix | `_.IMG-20230617-WA0085.jpg` |

Matching is case-insensitive (extension included), Unicode-normalised (NFC), and markers
can chain (`IMG_1 (1) copy.jpg`). If exactly one file is not a derived copy and all the
others are, that file is the suggested keeper; otherwise the group is **ambiguous** and
waits for your choice. `VID_20250822_205114.mp4` on its own is never treated as a copy.

**Optional rule — `--random-names-are-copies`:** some gallery and recovery apps give
copies random names made of 4–5 letters and 4 digits (`NBQE3618.jpg`, `RUHHE4377.JPG`).
With this flag, such files count as copies whenever the group also has a real-named file,
and the original is chosen among the real-named files. Off by default.

To add a marker, add a row to `CopyMarkers.table` in
`Sources/DoppioCore/Decide/CopyMarkers.swift` and a test row in `CopyMarkersTests`.

## How Doppio keeps your files safe

- **Contents, not names.** Duplicates are proven by size, SHA-256 *and* a byte-by-byte
  comparison.
- **Audit is strictly read-only.** Files are opened `O_RDONLY | O_NOFOLLOW`; nothing is
  written into the scanned folders (no xattrs, no caches); iCloud placeholders are not
  downloaded. A test snapshots a fixture tree (paths, sizes, mtimes, ctimes, xattrs,
  hashes) before and after an audit and asserts nothing changed.
- **Unreadable means unknown.** Files that can't be read, or that change during the scan,
  are reported and left out — never assumed unique or duplicate.
- **Packages are off-limits.** Nothing inside a Photos library or app bundle is ever read.
- **Hard links are never offered for deletion.**
- *(Phase 2)* Files only ever go to the **Trash** (`FileManager.trashItem`), never deleted;
  every action is logged and can be undone with `doppio restore`; just before each file is
  trashed Doppio re-checks that the kept copy still exists and is still byte-identical.

## Permissions (Full Disk Access)

macOS protects some locations (Desktop, Documents, Downloads, external and network
volumes, other apps' data). Without permission, files there show up as *unreadable* in
the report — they're never guessed about. To scan them from the command line, give
your terminal app Full Disk Access: **System Settings → Privacy & Security → Full Disk
Access → +** and add Terminal (or iTerm, …), then restart it.

## Project layout

```
Sources/DoppioCore/   scanning, comparison, suggestions, reports (no UI)
  Scan/      walker, exclusions, media filter, scan roots
  Compare/   read-only file access, hashing, byte comparison, pipeline
  Decide/    copy markers, suggestions, duplicate group model
  Report/    audit runner, JSON/CSV/console output
Sources/doppio/       command-line tool (swift-argument-parser)
Tests/DoppioCoreTests fixture generator + tests
```

## Roadmap

1. ✅ Scanning + `doppio audit`
2. Trash, logging, `doppio clean`, `doppio restore`
3. SwiftUI app (SwiftPM + app-bundle script; no Xcode required)
4. Optional hash cache in `~/Library/Application Support/Doppio`
