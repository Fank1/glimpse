# Glimpse

A KOReader plugin for peeking at maps, family trees and other reference
images from anywhere in a book, without losing your reading position.

Instead of bookmark → table of contents → find the map → navigate back, you
open Glimpse (ideally via a gesture), swipe through the reference images the
book contains, zoom and pan, and close it. You're still exactly where you
were.

<p align="center">
  <img width="380" alt="Glimpse in action — swiping through a book's maps and reference images without leaving your page" src="https://github.com/Fank1/glimpse/releases/download/v0.1.43/example-video-framed.gif">
  &nbsp;
  <img width="380" alt="A reference map opened full-screen in the Glimpse viewer" src="https://github.com/Fank1/glimpse/releases/download/v0.1.43/map-framed.png">
</p>

## What it does

- Scans the EPUB's HTML directly for images and **filters out ornaments,
  icons, dividers, covers and publisher chrome**, judging each image by its
  size and aspect ratio, repetition across chapters, filename and alt text,
  position in the book, and captions (a genuine caption, a figure-style
  filename, or a reference name like `map`/`family-tree`/`diagram` keeps an
  image; boilerplate text doesn't). Illustrated non-fiction — where the book
  already keeps many figures — automatically gets a gentler size floor, so its
  smaller diagrams and charts come through too, while novels stay strict.
- Remembers the **last image you viewed** per book, including its **zoom
  level and pan position**, and reopens right where you left off, handy
  when you keep returning to the same corner of the same map.
- Spoiler-safe by default: only searches **up to your current position**
  (per chapter); switchable to the whole book. When nothing has appeared
  yet, the empty state offers a **one-time whole-book search** without
  changing the setting.
- **Night-mode friendly:** line-art illustrations with transparent
  backgrounds get a white backing so they stay visible (and clean-edged)
  in night mode instead of vanishing against the dark page.

## Installation

1. Download the latest `glimpse-vX.Y.Z.koplugin.zip` from the
   [releases page](https://github.com/Fank1/glimpse/releases).
2. Unzip it and copy the `glimpse.koplugin/` folder into KOReader's
   `plugins/` directory.
3. Restart KOReader.

After that, updates install from within KOReader: Tools → Glimpse →
Updates → *Check for updates*.

## Usage

- **Menu:** with a book open: Tools (wrench icon) → Glimpse → *Open
  Glimpse* (greyed out when no book is open).
- **Gesture (recommended):** Settings → Taps and gestures → Gesture manager →
  pick a gesture → *Reader* → **Open Glimpse**. One-touch access is
  the whole point of the plugin. The Glimpse menu's top row shows which
  gesture (if any) currently opens it; tap that row for the exact steps,
  and the first time you open Glimpse from the menu without a gesture bound
  you get a one-time reminder to set one.
- **Dot indicator:** tap it to jump near that image directly, not just
  swipe through one at a time; its tap target is padded well beyond the
  dots themselves. A small image opens a bit larger than its native
  size already (up to 150%, never more than actually fits); double-tap
  zooms to the maximum — 200% of the image's own resolution by default,
  adjustable under Advanced → *Maximum zoom* — and again to return. A
  "Reset" button only appears once you're actually zoomed past the
  resting view.
- **Zoom control (optional):** add *Show Zoom Controls* from Quick Actions to
  put a vertical **+ / fit / −** pill in the viewer, above the corner
  buttons. Plus and minus step the zoom; the middle "fit" button returns to
  the resting view (greyed out while you're already fitted). With it on, the
  step buttons replace the "Reset" button as the way back to fit.
- **Mode switch (⋯ menu):** the viewer's ⋯ menu shows *Mode: Spoiler-free*
  / *Mode: All images*; tap it to flip the mode and reopen on the
  same image where possible, with a brief notice naming the mode you
  switched to. The gallery heading tells you how many images the chapter
  scope is holding back.
- **Quick Actions:** the contents of the ⋯ menu are configurable under
  Tools → Glimpse → *Quick Actions* — hide the rows you don't use, or add
  nav buttons and captions to it. *Gallery* always sits at the bottom of the
  ⋯ menu as its own item (it's the most common jump), so it isn't listed
  among the configurable rows.

### Settings (Tools → Glimpse)

| Setting | Meaning |
| --- | --- |
| Enable Glimpse *(checkbox, on)* | Master switch. When off, the bound gesture and *Open Glimpse* do nothing, silencing Glimpse without unbinding its gesture. |
| Mode: Show images up to current chapter *(default)* | Images past your current chapter stay hidden (no spoilers). |
| Mode: Show all images | Everything, incl. parts you haven't reached. |
| Include Bookmarks in Gallery *(checkbox, off)* | Sits just under Mode. Also show pages you've bookmarked (the dogear) in the Gallery, rendered as page thumbnails and marked with a bookmark badge, interleaved with the images in reading order. A quick way to keep a reference page a swipe away. Shown regardless of the spoiler scope. Also available in the viewer's ⋯ menu (add it under Quick Actions). |
| Quick Actions | Choose which actions appear in the viewer's ⋯ menu: Ignore Image, the Mode switch, Rotate image, Show in Book, Nav Buttons, Zoom Controls, Image Captions, Include Bookmarks in Gallery and Invert in Night Mode. Several are off until you add them. (Gallery is always present, pinned to the bottom of the ⋯ menu as its own item, so it isn't in this list. Reset Rotation is automatic, shown while an image is rotated. Ignored images are added back from the Gallery's Ignored tab. Rotate and Ignore are replaced by *Remove bookmark* on a bookmarked page.) |
| Settings → Show Nav Buttons *(checkbox, off)* | Show ‹ and › buttons in the viewer for switching between images. |
| Settings → Show Zoom Controls *(checkbox, off)* | Show a vertical +/fit/− control in the viewer for zooming; the middle button returns to the fitted view. |
| Settings → Invert Images in Night Mode *(checkbox, off)* | While KOReader's night mode is on, show images inverted (light lines on a dark background). Also on the viewer's ⋯ menu. |
| Settings → Show image captions *(checkbox, on)* | Show the image's caption from the book as a solid tab tucked into the viewer's top-left corner (white with black text in day mode, black with white text at night), wrapping onto multiple lines for longer captions. |
| Settings → Maximum zoom *(150%–400%, default 200%)* | How far you can zoom in, as a percentage of the image's own resolution. Double-tap jumps to this level and pinch stops there. Higher shows more on detailed maps; past 100% is upscaling, so very high can look soft. |
| Settings → Suppress "format not supported" notice *(checkbox, off)* | Silence the message shown when Glimpse is opened on a format it doesn't support (PDF, comics, manga). Handy if a reading gesture sometimes triggers Glimpse on non-EPUB files. |
| Settings → Enable top menu tap zone *(checkbox, on)* | While the viewer is open, a tap along the top edge opens KOReader's top menu (only that one, never the bottom menu) over the drawer. Off leaves the top edge inert. |
| Settings → Gestures → Double-tap for maximum zoom *(checkbox, on)* | Double-tap the image to jump to the maximum zoom (centered on the tap) and again to return to fit. Off disables the double-tap. |
| Settings → Gestures → Swipe left/right to navigate *(checkbox, on)* | Swipe across the image to move to the next/previous image. Off disables it (the Gallery's swipe-to-page is unaffected). |
| Settings → Gestures → Pinch to zoom in/out *(checkbox, on)* | Pinch or spread on the image to zoom. Off disables the pinch/spread zoom. |
| Advanced → Disable irrelevant image filtering *(checkbox, off)* | Normally Glimpse sets aside covers, publisher logos, ornaments and other non-reference imagery. Turn this on to switch that off and see every image in the book. |
| Advanced → Suppress "format not supported" notice *(checkbox, off)* | Silence the message shown when Glimpse is opened on a format it doesn't support (PDF, comics, manga). Handy if a reading gesture sometimes triggers Glimpse on non-EPUB files. |
| Advanced → Disable shadows *(checkbox, off)* | Remove the drawer's drop shadow — the main cause of e-ink ghosting behind the drawer. No visible effect on LCD screens. |
| Advanced → Fast image switching *(checkbox, on)* | Switch between images with a quick, flashless refresh instead of a full clear. On by default: faster and no flash. Turn it off if the previous image ghosts through the next one — most noticeable on detailed maps and slower e-ink panels. No visible effect on LCD screens. |
| Advanced → Rescan this book | Drop the cached scan (cached in the book's own `.sdr` sidecar folder, so it travels with the book between devices); use if the file was replaced or images seem out of date. |
| Updates → Check for updates | Fetch the latest GitHub release and install it in place (with backup and rollback), then offer a restart. |
| Updates → Include pre-release versions *(checkbox, off)* | Also offer releases marked pre-release on GitHub: test builds, at your own risk. Normal update checks never see those. |

The menu also shows (dimmed, informational) which gesture currently
opens Glimpse, at the top of the list.

### Gallery

⋯ → *Gallery* shows every image as a Pinterest-style masonry grid, each
thumbnail with a subtle rounded outline and a small number badge showing
its reading order, keeping its own aspect ratio instead of being cropped to
a uniform tile. Paged when there are enough to browse (the page arrows are
always present, greyed out when there's only one page); a *Back* button
returns to the normal viewer. Tap a thumbnail to jump straight to that
image instead.

With **Include Bookmarks in Gallery** on, the pages you've bookmarked
(the dogear) appear in the grid too, rendered as page thumbnails (via
KOReader's own page-render service) and marked with a bookmark badge,
interleaved with the images in reading order. Tap one to see the page
full-size in the viewer; *Show in Book* jumps to it. While a bookmarked page
is shown full-size, a small pill in the top-left corner names it — its page
number and chapter — so you always know which bookmark you're looking at. To
drop one, use *Remove bookmark* (long-press it in the Gallery, or the viewer's
⋯ menu) — that deletes the dogear in the book itself, not just its Glimpse cell.

**Gallery / Ignored.** When the relevance filter has set some images aside
(or you've ignored some), a segmented switcher on the Gallery's bottom bar
shows both pools at once — **Gallery** (the images you keep) and the
**Ignored** pile — each with its count, the current one highlighted. Tap a
segment to switch. The Ignored pile is every image not in the Gallery,
whether the filter dropped it as irrelevant *or* you ignored it by hand. The
header also names the current view and its count.
**Long-press** a thumbnail and a small menu pops up just above it — *Ignore this
image* in the Gallery, *Add back to Gallery* in the Ignored pile — while the
pressed thumbnail takes a bold outline and the others dim, so it stands out.
(Tapping an Ignored thumbnail does nothing; the long-press is the way in.) That's the fix
when the filter set aside an image you actually want — the map it deemed
irrelevant — without switching to *Mode: All images*. The moves persist per
book. If the filter set aside *everything*, the empty state offers **Review
filtered-out** to open straight into the Ignored pile. (The switch is on the
bottom bar because the top strip is reserved for KOReader's top menu.)

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
