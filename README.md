# Glimpse

A KOReader plugin for peeking at maps, family trees and other reference
images from anywhere in a book, without losing your reading position.

Instead of bookmark → table of contents → find the map → navigate back, you
open Glimpse (ideally via a gesture), swipe through the reference images the
book contains, zoom and pan, and close it. You're still exactly where you
were.

## What it does

- Scans the EPUB's HTML directly for images and **filters out ornaments,
  icons, dividers, covers and publisher chrome**, judging each image by its
  size and aspect ratio, repetition across chapters, filename and alt text,
  position in the book, and captions (a genuine caption or figure-style
  filename keeps an image; boilerplate text doesn't).
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
Updates → *Check for updates*.

## Usage

- **Menu:** with a book open: Tools (wrench icon) → Glimpse → *Show book
  images*.
- **Gesture (recommended):** Settings → Taps and gestures → Gesture manager →
  pick a gesture → *Reader* → **Glimpse: book images**. One-touch access is
  the whole point of the plugin.
- **Dot indicator:** tap it to jump near that image directly, not just
  swipe through one at a time; its tap target is padded well beyond the
  dots themselves. Double-tap an image to zoom in (150% of its natural
  size if it's small enough to already show at 100%, otherwise 2× the
  fitted view) and again to return; a "Fit" button only appears once
  you're actually zoomed past that point.

### Settings (Tools → Glimpse)

| Setting | Meaning |
| --- | --- |
| Mode: up to current chapter *(default)* | Images past your current chapter stay hidden (no spoilers). |
| Mode: all images | Everything, incl. parts you haven't reached. |
| Restore hidden images | Undo the viewer's per-book **Remove image from collection**. |
| Rescan this book | Drop the cached scan (scans are cached per book file). |
| Advanced → Hide irrelevant images *(checkbox, on)* | Hides covers, publisher logos, ornaments and other non-reference imagery. Off = every image in the book. |
| Advanced → Show image captions (beta) *(checkbox, on)* | Overlay the image's caption from the book in the viewer's top-left corner. |
| Updates → Check for updates | Fetch the latest GitHub release and install it in place (with backup and rollback), then offer a restart. |
| Updates → Include pre-release versions *(checkbox, off)* | Also offer releases marked pre-release on GitHub: test builds, at your own risk. Normal update checks never see those. |

The menu also shows (dimmed, informational) which gesture currently
opens Glimpse, at the top of the list.

### Gallery

⋯ → *Gallery* shows every image as a Pinterest-style masonry grid, each
thumbnail with a subtle rounded outline (a heavier one marks the image
you're currently on), keeping its own aspect ratio instead of being
cropped to a uniform tile. Paged when there are enough to browse. Tap a
thumbnail to jump straight to that image in the normal viewer.

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
