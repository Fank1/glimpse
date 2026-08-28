# Glimpse

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/fanki)

A KOReader plugin for peeking at maps, family trees and other reference images from anywhere in a book, without losing your place.

No more bookmark → contents → find the map → navigate back. Open Glimpse, swipe through the book's reference images, zoom, and close. You're still exactly where you were.

<p align="center">
  <img width="380" alt="Glimpse in action: swiping through a book's maps and reference images without leaving your page" src="https://github.com/Fank1/glimpse/releases/download/v0.1.43/example-video-framed.gif">
  &nbsp;
  <img width="380" alt="A reference map opened full-screen in the Glimpse viewer" src="https://github.com/Fank1/glimpse/releases/download/v0.1.43/map-framed.png">
</p>

## Features

- **Finds the images worth seeing.** Maps, family trees, diagrams and illustrations surface automatically; covers, logos, ornaments and dividers are filtered out. Illustrated non-fiction keeps its smaller figures too.
- **Browse them all.** A Gallery lays every image out as a grid, and a tap jumps straight to any one.
- **Reopens where you left off.** Comes back to the last image you viewed, at the same zoom and pan. Handy when you keep returning to one corner of one map.
- **Spoiler-safe by default.** Shows only images up to where you're reading; switch to the whole book whenever you want.
- **Readable at night.** Line-art illustrations stay visible in night mode instead of vanishing into the dark page.
- **Customizable.** Choose where the drawer sits (a side panel, or a top or bottom band in portrait), arrange the viewer's ⋯ menu, add nav arrows, a zoom pill or a mini-map for panning while zoomed, and tune the zoom limit.

## Screenshots

<table align="center">
  <tr>
    <td align="center" width="33%"><img src="https://github.com/Fank1/glimpse/releases/download/readme-assets/viewer-day.png" width="100%"><br><sub>A diagram open in the viewer.</sub></td>
    <td align="center" width="33%"><img src="https://github.com/Fank1/glimpse/releases/download/readme-assets/viewer-night.png" width="100%"><br><sub>The same diagram in night mode.</sub></td>
    <td align="center" width="33%"><img src="https://github.com/Fank1/glimpse/releases/download/readme-assets/gallery.png" width="100%"><br><sub>The Gallery shows every image at once.</sub></td>
  </tr>
  <tr>
    <td align="center" width="33%"><img src="https://github.com/Fank1/glimpse/releases/download/readme-assets/layout.png" width="100%"><br><sub>Choosing where the drawer opens.</sub></td>
    <td align="center" width="33%"><img src="https://github.com/Fank1/glimpse/releases/download/readme-assets/bookmark-minimap.png" width="100%"><br><sub>A bookmarked page with the mini-map.</sub></td>
    <td align="center" width="33%"></td>
  </tr>
</table>

## Installation

The easiest way is [Storefront](https://github.com/ultimatejimmy/storefront.koplugin), a plugin browser for KOReader that installs and updates Glimpse for you.

To install manually:

1. Download the latest `glimpse-vX.Y.Z.koplugin.zip` from the [releases page](https://github.com/Fank1/glimpse/releases).
2. Unzip and copy the `glimpse.koplugin/` folder into KOReader's `plugins/`.
3. Restart KOReader.

After that, update from inside KOReader: Tools → Glimpse → Updates → *Check for updates*.

## Usage

**Open it.** With a book open: Tools → Glimpse → *Open Glimpse*. Better, bind a gesture under Settings → Taps and gestures → Gesture manager → pick a gesture → Reader → *Open Glimpse*. One-touch access is the whole point.

**In the viewer:**

- **Swipe** left/right to move between images.
- **Tap a dot** to jump straight to an image.
- **Double-tap** to zoom in, again to zoom back; drag to pan.
- Prefer buttons? Add a **zoom pill** (+ / fit / −) or **‹ › nav arrows** from Quick Actions.

**Switch modes** from the viewer's ⋯ menu: flip between *Spoiler-free* and *All images* without leaving your place.

**Make the ⋯ menu yours** under Tools → Glimpse → *Quick Actions*: hide rows you don't use, add nav buttons or captions. *Gallery* stays pinned at the bottom.

### Settings (Tools → Glimpse)

| Setting | What it does |
| --- | --- |
| **Enable Glimpse** | Master switch. Off silences Glimpse without unbinding its gesture. |
| **Mode** | Whether images past where you're reading stay hidden. Default hides them. |
| **Include Bookmarks in Gallery** | Also show your bookmarked pages in the Gallery, in reading order. |
| **Quick Actions** | Choose which actions appear in the viewer's ⋯ menu. |
| **Layout** | Where the drawer opens: a side panel (left/right), or a top or bottom band in portrait. |
| **Show Nav Buttons** | ‹ › arrows in the viewer for switching images. |
| **Navigation Loops Around** | ‹ › and swipes wrap past the ends; Gallery pages too. |
| **Show Zoom Controls** | A + / fit / − pill in the viewer for zooming. |
| **Show Mini Map** | While zoomed, a small overview marks the visible area; tap to jump. |
| **Invert Images in Night Mode** | Show images inverted (light on dark) in night mode. |
| **Show image captions** | Show the book's caption for an image, in the corner. |
| **Show bookmark label in corner** | On a bookmarked page, show its page number and chapter in the corner. |
| **Maximum zoom** | How far double-tap and pinch can zoom in (150–400%, default 200%). |
| **Enable top menu tap zone** | A tap along the top edge opens KOReader's top menu over the viewer. |
| **Gestures** | Toggle double-tap zoom, swipe-to-navigate, and pinch zoom. |
| **Disable irrelevant image filtering** | Show every image in the book, including covers and ornaments. |
| **Suppress "format not supported" notice** | Silence the message when Glimpse opens on a non-EPUB file. |
| **Disable shadows** | Remove the drawer's shadow if it leaves e-ink ghosting. |
| **Fast image switching** | Flashless refresh between images; turn off if images ghost through. |
| **Rescan this book** | Drop the cached scan if the file changed or images look stale. |
| **Check for updates** | Fetch and install the latest release, with a restart. |
| **Include pre-release versions** | Also offer test builds. |

### Gallery

⋯ → *Gallery* lays out every image as a masonry grid, numbered in reading order. Tap a thumbnail to jump to it; page through with the arrows.

With **Include Bookmarks in Gallery** on, your bookmarked pages appear in the grid too, in reading order. Tap one to view it full-size; *Show in Book* jumps there. To drop a bookmark, use *Remove bookmark* (long-press in the Gallery, or the ⋯ menu). It deletes the bookmark in the book itself, not just its Glimpse cell.

**Ignored images.** When the filter sets an image aside (or you ignore one), a **Gallery | Ignored** switcher on the bottom bar shows both piles with their counts. Long-press a thumbnail to *Ignore* it or *Add back to Gallery*. That recovers a map the filter hid but you actually wanted, without switching to *All images*. Your choices persist per book.

### Releasing

```sh
./release.sh 0.2.0 --notes "what changed"   # builds + publishes a PRE-release
./release.sh 1.0.0 --final                  # a real release, visible to updaters
DRYRUN=1 ./release.sh                       # build the zip only
```

Pre-releases are invisible to the normal update check (`releases/latest` skips them), so they form the opt-in test channel behind "Include pre-release versions".

## Translations

Glimpse is translated on [Crowdin](https://crowdin.com/project/glimpse-plugin), and help is welcome. No programming is needed: pick your language, fix the AI-drafted lines that sound wrong, and your work ships with the next version. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Scope and limitations

- **EPUB only** (and other HTML-based formats crengine renders). PDF, DjVu, comics and manga get a polite "not supported" message.
- Spoiler scope tracks the **chapter you're currently in**, not the furthest you've ever read.

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

The scanner takes an injected `read_file(archive_path)` function; inside KOReader that is crengine's `getDocumentFileContent` (with a libarchive fallback), in tests it reads the extracted fixture. Image dimensions are sniffed from file headers; no image decoding happens during a scan, and a full decode only happens for the image currently on screen.

## License

Glimpse is free software under the **GNU Affero General Public License v3.0 or later** (AGPL-3.0-or-later); full text in [LICENSE](LICENSE). Use it, fork it, modify it freely; if you distribute a modified version, ship its source under the same terms. Community translations via Crowdin are under the same licence.

Copyright (C) 2026 Erik Fanki
