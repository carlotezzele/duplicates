# Which file to keep: the naming rules

When several files have exactly the same contents, Doppio suggests which one to keep.
It decides **only from the file names**. Folder, dates, EXIF and size are never used.
Contents are already proven identical (size, SHA-256 and a byte-by-byte comparison).

The code lives in `Sources/DoppioCore/Decide/CopyMarkers.swift` and
`Sources/DoppioCore/Decide/DuplicateGroup.swift`. Every rule below has a test row in
`Tests/DoppioCoreTests/CopyMarkersTests.swift`.

## The core rule

1. A file is a **derived copy** if removing one or more copy markers from its name gives
   the name of **another file in the same group**.
   - Removing a marker is never enough on its own: the shorter name has to exist in the group.
   - Markers can be removed one after another:
     `IMG_1 (1) copy.jpg` → `IMG_1 (1).jpg` → `IMG_1.jpg`.
2. The **keeper** is the single file that is not a derived copy, and only when every
   other file is one.
3. In every other case the group is **ambiguous**, and you choose. Doppio never guesses.

If a group holds only copies, the least-derived one wins:
with `photo copy.jpg` and `photo copy 2.jpg`, `photo copy.jpg` is kept.

## Copy markers

Case-insensitive. Numbered markers take 1–3 digits.

| Position | Marker | Example of a copy |
|---|---|---|
| end of name | `_N` | `IMG_1234_1.jpg` |
| end of name | `-N` | `IMG_1234-1.jpg` |
| end of name | ` (N)` | `IMG_1234 (1).jpg` |
| end of name | ` N` (Finder) | `sunset 2.heic` |
| end of name | ` copy`, ` copy N` | `photo copy.jpg`, `photo copy 2.jpg` |
| end of name | ` - Copy`, ` - Copy (N)` | `photo - Copy.jpg`, `photo - Copy (2).jpg` |
| end of name | ` - Copia`, ` - Copia (N)` | `foto - Copia.jpg`, `foto - Copia (3).jpg` |
| end of name | ` copia`, ` copia N` | `foto copia.jpg`, `foto copia 2.jpg` |
| start of name | `Copy of ` | `Copy of beach.png` |
| start of name | `Copia di ` | `Copia di mare.png` |
| whole name | leading `.` (hidden copy) | `.Screenshot 2025-01-01 at 10.00.00.png` |
| end of name | `_` + 13-digit epoch ms (2017–2033) | `IMG_20221001_152443_1706717647603.jpg` |
| start of name | `-` + 10-digit epoch s + `-` (Android trash) | `-1764628937-IMG_20221001_152443.jpg` |
| start of name | `.trashed-` + epoch s + `-` | `.trashed-1764628937-IMG_1234.jpg` |
| start of name | `_.` | `_.IMG-20230617-WA0085.jpg` |

Markers apply to the name **without** its extension, except the leading dot, which
applies to the whole name.

## Comparing names

- Names are compared after Unicode NFC normalisation and lowercasing, so
  `Caffè.jpg` matches `Caffè (1).jpg` whichever way the `è` is encoded.
- **The extension must match** (ignoring case): `IMG_7.JPG` and `img_7 (1).jpg` match,
  but `IMG_1.jpg` and `IMG_1 (1).jpeg` do not.

## Safety rules

Doppio never treats these as copies:

- **Date and time numbers.** `VID_20250822_205114.mp4` is not a copy of `VID_20250822.mp4`,
  because 6 digits are never a copy number.
- **Years.** `Trip 2024.jpg` is not a copy of `Trip.jpg`, because ` 2024` has 4 digits.
- **Look-alike words.** `holiday_copy.jpg` is not a copy of `holiday.jpg`, because `_copy`
  is not a marker.
- **Implausible timestamps.** A 13-digit number from 2009, or an 11-digit number, is not read
  as a timestamp.
- **Names that would become empty.** `_1.jpg` is not a copy of `1.jpg`.

These groups are left for you to decide:

- The same name in two folders (`a/IMG_1.jpg`, `b/IMG_1.jpg`).
- Only copies, with no original: `IMG_1234 (1).jpg` and `IMG_1234 (2).jpg`.
- Two originals: `photo.jpg`, `photo.jpg` and `photo copy.jpg`.
- A hidden file whose name matches nothing: `.photo.jpg` and `other.jpg`.
- An unrelated name: `IMG_9999.DNG` and `HBIK8661.DNG` (unless the optional rule below is on).

### Hard links

A hard-linked file has several names. It counts as a copy only if **all** of its names are
derived. If any copy in a group is hard-linked, the group is ambiguous: trashing a hard
link frees no space.

## Optional rule: random-looking names are copies

`--random-names-are-copies` (CLI), or *Treat random-looking names as copies* (app).
Off by default.

Some gallery and recovery apps give copies names made of **4–5 letters and 4 digits**
(`NBQE3618.jpg`, `RUHHE4377.JPG`, also hidden: `.NBQE3618.jpg`). With the rule on:

- such a file counts as a copy, but only if the group also has at least one real-named file;
- the keeper is then chosen among the real-named files using the core rule;
- a group made only of random names stays ambiguous;
- 2 letters (`AB1234`) or 6 letters (`ABCDEF1234`) are not random-looking.

| Group | Kept |
|---|---|
| `IMG-20241227-WA0019.jpg`, `HKNM5184.JPG` | `IMG-20241227-WA0019.jpg` |
| `RUHH4377.JPG`, `IMG_20250402_191604.jpg`, `SZQU3028.JPG` | `IMG_20250402_191604.jpg` |
| `HKNM5184.JPG`, `RYND3759.JPG` | ambiguous |

## Comparison with the earlier Python script (`dedup_foto.py`)

Doppio replaced a Python script that applied three rules in order, where the first rule
to find a single winner decided:

1. keep the only file whose name does not start with `.`;
2. keep the only file with a camera/app name (`IMG VID DSC DSCN DCIM PXL MVIMG MOV PANO
   BURST WA… WhatsApp Image/Video Screenshot Snapchat`, then a digit);
3. keep the only file without a copy marker at the end (`_N`, ` (N)`, `(N)`, ` copia`,
   ` copy`, ` kopia`, with 1–2 digits).

None of those rules checked that the shorter name exists in the group, or that the
extensions match. So the script sometimes picks a keeper where Doppio stays on the safe
side, and sometimes the two disagree:

| Group | Script | Doppio |
|---|---|---|
| `trip_12.jpg`, `beach.jpg` | keeps `beach` | ambiguous |
| `.x.jpg`, `other.jpg` | keeps `other` | ambiguous |
| `IMG_1.jpg`, `Vacanza mare.jpg` | keeps `IMG_1` (trashes the hand-picked name) | ambiguous |
| `photo.jpg`, `photo (1).png` | keeps `photo.jpg` | ambiguous (different extension) |
| `photo.jpg`, `photo(1).jpg` | keeps `photo.jpg` | ambiguous (no space before `(1)`) |
| `IMG_123.jpg`, `IMG.jpg` | keeps `IMG_123.jpg` (camera-name rule) | keeps `IMG.jpg` |
| `IMG_1.jpg`, `IMG_1 (1).jpg` | ambiguous (reads `_1` in `IMG_1` as a marker) | keeps `IMG_1.jpg` |

Possible additions to Doppio taken from the script: `(N)` without a space (Google Takeout)
and ` kopia` / ` kopia N` (Finder in Polish).

## Adding a marker

Add a row to `CopyMarkers.table` and a test row to `CopyMarkersTests.cases`, for the
copy and also for at least one look-alike name that must **not** match.
