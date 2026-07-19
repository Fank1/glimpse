# Glimpse

A KOReader plugin for peeking at maps, family trees and other reference
images from anywhere in a book, without losing your reading position.

Instead of bookmark → table of contents → find the map → navigate back, you
open Glimpse (ideally via a gesture), swipe through the reference images the
book contains, zoom and pan, and close it. You're still exactly where you
were.

## What it does

- Scans the EPUB's HTML directly for images and **filters out ornaments,
  icons, dividers and publisher chrome** using:
  - pixel dimensions and aspect ratio (per filter level)
  - repetition across chapters (chapter-head decorations)
  - dimension series: ≥4 unique files with identical pixel dimensions are
    chapter/part-opener art, unless they carry distinct real captions
    (genuine figure plates)
  - decorative alt text ("Chapter 1 …", "Book Title, …", "… Back Ad logo",
    publisher names, advertisements) and chrome filenames (`author.jpg`,
    `titlepage.jpg`, `endpaper.jpg`, `*logo*`, publisher tokens like `_tp_`).
    A chrome-named file is only rescued by a strong caption; "Title by
    Author" alt text doesn't count. Conversely, figure-naming conventions
    (`f0156-01.jpg`, `fig12.png`) earn the same relief as a caption.
  - front matter: uncaptioned cover-shaped portrait images in the first 3
    spine items (unflagged cover variants and title pages)
  - HTML metadata (`<figure>`/`<figcaption>`, `alt`, `title`) as a positive
    signal: captioned images get more lenient size thresholds.
- Remembers the **last image you viewed** per book, including its **zoom
  level and pan position**, and reopens right where you left off, handy
  when you keep returning to the same corner of the same map.
- Spoiler-safe by default: only searches **up to your current position**
  (per chapter); switchable to the whole book. When nothing has appeared
  yet, the empty state offers a **one-time whole-book search** without
  changing the setting.

## Installation

1. Download the latest `glimpse-vX.Y.Z.koplugin.zip` from the
   [releases page](https://github.com/Fank1/glimpse/releases).
2. Unzip it and copy the `glimpse.koplugin/` folder into KOReader's
   `plugins/` directory.
3. Restart KOReader.

After that, updates install from within KOReader: Tools → Glimpse →
*Check for updates*.

## Usage

- **Menu:** with a book open: Tools (wrench icon) → Glimpse → *Show book
  images*.
- **Gesture (recommended):** Settings → Taps and gestures → Gesture manager →
  pick a gesture → *Reader* → **Glimpse: book images**. One-touch access is
  the whole point of the plugin.

### Settings (Tools → Glimpse)

| Setting | Meaning |
| --- | --- |
| Search only what you've read *(default)* | Images past your current chapter stay hidden (no spoilers). |
| Search the whole book | Everything, incl. parts you haven't reached. |
| Show Image Captions *(checkbox, on)* | Overlay the image's caption from the book in the viewer's top-left corner. |
| Filter irrelevant images *(checkbox, on)* | Hides covers, publisher logos, ornaments and other non-reference imagery. Off = every image in the book. |
| Restore hidden images | Undo the viewer's per-book **Remove image from collection**. |
| Rescan this book | Drop the cached scan (scans are cached per book file). |
| Check for updates | Fetch the latest GitHub release and install it in place (with backup and rollback), then offer a restart. |
| Include pre-release versions *(checkbox, off)* | Also offer releases marked pre-release on GitHub: test builds, at your own risk. Normal update checks never see those. |

### Releasing

```sh
./release.sh 0.2.0 --notes "what changed"   # builds + publishes a PRE-release
./release.sh 1.0.0 --final                  # a real release, visible to updaters
DRYRUN=1 ./release.sh                       # build the zip only
```

Pre-releases are invisible to the normal update check (`releases/latest`
skips them), so they form the opt-in test channel behind "Include
pre-release versions".

## Scope and limitations

- **EPUB (and other crengine-rendered zip/HTML formats) only.** PDF/DjVu
  have no HTML metadata to filter on; other formats get a polite message.
- "Read so far" granularity is the **chapter** (spine item): images in the
  chapter you are currently in are shown. It tracks your *current* position,
  not the furthest you've ever read.
- Images inlined as `data:` URIs or applied via CSS backgrounds are ignored.

## Development

```
plugin/                     the plugin (copy/stage as glimpse.koplugin/)
  main.lua                  KOReader wiring: menu, gesture action, scan cache,
                            viewer subclass (dots, captions, hide, swipe-nav)
  glimpse_scanner.lua       pure Lua, no KOReader deps: EPUB container/OPF/HTML
                            parsing, image-header dimension sniffing (PNG,
                            JPEG, GIF, WebP, BMP, SVG), filter heuristics
builder/
  check.sh                  syntax gate + fixture regen + unit tests; run it
                            before calling any change done
  make_fixture_epub.py      deterministic fixture EPUB (stdlib only) with
                            trap cases (ornaments, dividers, commented-out
                            markup, URL-encoded paths, SVG)
  scanner_tests.lua         headless tests against the extracted fixture
  smoke_userpatch.lua       userpatch that exercises the live plugin inside a
                            running KOReader (see file header)
  stage.sh                  checks + builds dist/glimpse.koplugin + zip
```

The scanner takes an injected `read_file(archive_path)` function; inside
KOReader that is crengine's `getDocumentFileContent` (with a libarchive
fallback), in tests it reads the extracted fixture. Image dimensions are
sniffed from file headers; no image decoding happens during a scan, and a
full decode only happens for the image currently on screen.
