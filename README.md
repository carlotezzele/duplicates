# Doppio

A safe duplicate photo/video finder for macOS. Doppio finds files whose contents are
**100% identical** and helps you reclaim disk space without ever risking a unique file.
Safety beats speed and convenience everywhere.

> **Status: Phase 3**: the scanning engine (`DoppioCore`), the `doppio` command-line tool
> (`audit`, `clean`, `restore`) and the **Doppio app** for macOS.

## Requirements

- macOS 14 or later
- Swift 6 toolchain: the Xcode **Command Line Tools** are enough (`xcode-select --install`).
  Full Xcode is not required.

## Build, test, install

```sh
make build          # debug build → .build/debug/doppio
make test           # full test suite (Swift Testing)
make install-cli    # release build → ~/.local/bin/doppio  (PREFIX=/usr/local to change)
make app            # build/Doppio.app (SwiftPM + scripts/build-app.sh, ad-hoc signed)
make install-app    # copies it to ~/Applications/Doppio.app
make run-app        # builds and opens it
```

The app is built without Xcode: `scripts/build-app.sh` compiles the `DoppioApp` target
with SwiftPM, wraps it in a bundle with `App/Info.plist` and `App/Doppio.icns`, and signs
it ad hoc (`codesign -s -`). The icon is drawn by `scripts/make-icon.swift`
(`make icon` regenerates it).

`make test` also runs the app's tests. To render every screen of the app to PNGs (handy
for checking the UI without clicking through it):
`DOPPIO_SNAPSHOTS=/tmp/doppio-snapshots make test`.

`make test` adds a compiler flag that the Command Line Tools need to find Swift Testing's
macro plugin; with full Xcode, plain `swift test` works too.

## The app

Open **Doppio.app**, drop folders or drives onto the window (or click **Choose
Folders…**), pick the options, and click **Scan**. Scanning only reads files and can be
cancelled at any time.

The results have two tabs:

- **Suggested**: groups with an obvious original. Every group is pre-checked; uncheck
  any you want to leave alone. Expand a row to see which file is kept and which go to
  the Trash.
- **Needs Your Choice**: the other groups, one at a time, side by side. Each file shows
  a Quick Look thumbnail (HEIC, RAW and video included), its folder, size, capture date,
  and creation and modification dates. **Nothing is pre-selected.**

| Key | Action (Review menu) |
|---|---|
| `1`–`9` | keep that file, then go to the next group |
| `K` | keep all files in this group |
| `→` / `←` | next / previous group |
| Space | Quick Look the selected file (click a card to select it; double-click previews) |
| ⌘R | reveal the selected file in Finder |
| ⇧⌘E | export the audit report (JSON + CSV) |
| ⌘N | new scan |

**Move N Files to Trash…** opens a confirmation sheet with the totals. Nothing is moved
until you click **Move to Trash** (it deliberately has no keyboard shortcut). The final
screen shows what was moved and what wasn't (with reasons), and offers **Open Trash**,
the log, the summary, and **Put Everything Back…**. Quitting while files are being moved
waits for the current file to finish.

The app uses the same `DoppioCore` code as the command line, so every safety check below
applies to it too.

## Command line

### Audit (read-only)

```sh
doppio audit ~/Pictures/Export /Volumes/Backup/Phone
doppio audit /Volumes/HDD/Photos --jobs 1             # spinning disk: keep 1 (the default)
doppio audit ~/Downloads --all-types                  # every file type, not just photos/videos
doppio audit /Volumes/MyDisk/Photos --random-names-are-copies  # see "Automatic suggestions"
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

### Clean (moves copies to the Trash, after you confirm)

```sh
doppio clean /Volumes/MyDisk/Photos
doppio clean ~/Pictures/Export /Volumes/Backup/Phone --jobs 2
```

`clean` takes the same options as `audit` and must be run in a terminal: it never takes
"yes" from a pipe or a script. After the scan it goes through three steps, and **nothing
is moved before the last one**:

1. **Automatic suggestions.** Doppio shows how many files and how much space, with a
   couple of examples, and asks whether to include them (`l` lists every file in a pager).
2. **Groups that need your choice** (optional). One group at a time, with each file's
   path, creation/modification dates and capture date (EXIF / QuickTime metadata). Nothing
   is pre-selected.

   | Key | Action |
   |---|---|
   | `1`–`9`… | keep that file; the other copies go to the Trash |
   | `s` | keep all files in this group |
   | Enter | next group (leaves the current choice as it is) |
   | `b` | back to the previous group |
   | `l` | show this group again |
   | `o N` | preview file N with Quick Look |
   | `r N` | show file N in Finder |
   | `q` | stop reviewing (the remaining groups keep all their files) |
   | `?` | help |

3. **Final confirmation**: the total number of files and space, then `[y/N]`.

Then, one file at a time, Doppio re-checks everything (see below), moves the file to the
Trash and logs it. Ctrl-C stops after the current file. At the end it prints what was
moved, what was not and why, and the command to undo it.

### Restore

```sh
doppio restore                                   # list recent clean sessions
doppio restore ~/Library/Logs/Doppio/doppio-clean-20261017-101500.jsonl --dry-run
doppio restore ~/Library/Logs/Doppio/doppio-clean-20261017-101500.jsonl
```

Restore puts the files from one clean session back where they were, after showing what
it will do and asking `[y/N]`. A file is put back only if:

- it is still in the Trash, and is still the very file Doppio moved there (same inode,
  size and SHA-256);
- its original folder still exists (otherwise it is skipped and reported);
- nothing else is at its original path. The move uses `renamex_np(RENAME_EXCL)`, which
  cannot overwrite anything, even in a race.

Everything else stays in the Trash and is listed with the reason. Running restore twice
is harmless.

### Logs

Every clean and restore session writes, in `~/Library/Logs/Doppio/`:

- `doppio-clean-<date>.jsonl` (or `doppio-restore-…`): one JSON object per line, never
  overwritten. For each file there is an `intent` line written and fsync'ed **before**
  the move, then a `trashed` line (or `skipped` / `failed` with the reason). Each entry
  records the time, the original path, its path in the Trash, the kept file, size,
  SHA-256 and inode.
- `doppio-clean-<date>.txt`: the same in plain English, plus the restore command.

If Doppio is interrupted, the log still shows exactly what was in progress, and restore
reports such files instead of guessing.

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

The full rule set, with the ambiguous cases, is in [docs/KEEP-RULES.md](docs/KEEP-RULES.md).

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
- **Hard links are never offered for deletion**, and a file that gains a hard link after
  the scan is skipped.
- **Trash only.** Files go to the Trash with `FileManager.trashItem` (the right Trash for
  each volume, including external drives). Doppio has no code path that deletes a file.
  If a volume has no Trash (some network shares), the file is skipped and reported; there
  is no fallback.
- **You confirm everything.** Suggestions are never executed automatically; `clean`
  refuses to run without a terminal, and nothing in an ambiguous group is pre-selected.
- **Checked again right before each move**, in `DoppioCore` (so the app gets the same
  guarantees). A file is moved only if *all* of these hold at that moment:
  - it is inside a scanned folder, by its real path (a folder swapped for a symlink after
    the scan is caught), and not inside a package such as a Photos library;
  - it is still the same file the scan saw (device, inode, size, modification time) and
    has a single link;
  - the file being kept still exists, is unchanged, and is a different physical file;
  - the two are **byte-identical right now**, and the bytes still hash to the SHA-256
    found by the scan (this catches edits that kept the size and modification time).
  - Every group keeps at least one file: a plan can't trash its own kept file, and two
    plans can't touch the same file.
- **Logged and undoable.** Every action is logged before it happens; `doppio restore`
  puts files back without ever overwriting anything.

Each of these rules has a test (`Tests/DoppioCoreTests/CleanTests.swift`,
`RestoreTests.swift`). Most use a stand-in Trash folder inside the test's temporary
directory; one round trip uses the real Trash with a tiny file named `doppio-test-…`,
and restores it at the end.

## Permissions (Full Disk Access)

macOS protects some locations (Desktop, Documents, Downloads, external and network
volumes, other apps' data). Without permission, files there show up as *unreadable* in
the report — they're never guessed about.

- **App:** folders you pick or drop are usually allowed after macOS asks once. For
  everything else, add Doppio.app under **System Settings → Privacy & Security → Full
  Disk Access**. Because the app is signed ad hoc, macOS may ask again after each rebuild.
- **Command line:** give your terminal app Full Disk Access (same place: add Terminal,
  iTerm, …), then restart it.

## Project layout

```
Sources/DoppioCore/   scanning, comparison, suggestions, reports (no UI)
  Scan/      walker, exclusions, media filter, scan roots
  Compare/   read-only file access, hashing, byte comparison, pipeline
  Decide/    copy markers, suggestions, duplicate group model
  Report/    audit runner, JSON/CSV/console output
  Trash/     plans, safety checks, cleaner (Trash only), restorer
  Log/       append-only session logs and their plain-text summaries
  Metadata/  capture date (ImageIO / AVFoundation)
Sources/doppio/       command-line tool (swift-argument-parser)
Sources/DoppioApp/    SwiftUI app (state in AppModel; all file changes via DoppioCore)
App/                  Info.plist and icon for the app bundle
scripts/              build-app.sh, make-icon.swift/.sh
Tests/DoppioCoreTests fixture generator + tests
Tests/DoppioAppTests  app model and flow tests, opt-in screen snapshots
```

## Roadmap

1. ✅ Scanning + `doppio audit`
2. ✅ Trash, logging, `doppio clean`, `doppio restore`
3. ✅ SwiftUI app (SwiftPM + app-bundle script; no Xcode required)
4. Optional hash cache in `~/Library/Application Support/Doppio`

## License

MIT, see [LICENSE](LICENSE).
