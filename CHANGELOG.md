# Changelog

## Unreleased (in pre-release testing, for the next public release)

Everything below has shipped only in pre-release builds so far. It must be
folded into the notes of the next public release.

**🔖 Bookmarked pages in the Gallery**
- Turn on Tools → Glimpse → Advanced → Include bookmarked pages to also see the pages you've bookmarked (the dogear) in the Gallery, rendered as page thumbnails and marked with a bookmark badge, sitting in reading order among the images. A quick way to keep a reference page (a glossary, a family tree, a map that lives in the text) a swipe away. Tap one to read it full-size, or use Show in Book to jump there.
- Open a bookmarked page full-size and a small label in the top-left corner names it — its page number and chapter — so you always know which bookmark you're looking at.
- *Remove bookmark* — long-press a bookmarked page in the Gallery, or use the viewer's ⋯ menu — deletes the dogear from the book itself, not just its Glimpse cell.

**🔍 Zoom, your way**
- Double-tap now zooms to 200% by default (was 150%), so a quick tap reveals more detail.
- New setting to choose how far you can zoom, from 150% up to 400% (Tools → Glimpse → Advanced → Maximum zoom).
- Optional on-screen Zoom Controls: a small vertical plus / fit / minus strip in the viewer for zooming without pinching or double-tapping. Turn it on under Tools → Glimpse → Show Zoom Controls (or the viewer's Quick Actions). The plus and minus dim when you reach a limit, and the middle button returns to the fitted view.

**🧭 A tidier menu**
- New "Enable Glimpse" switch at the top turns the whole plugin on or off, so you can silence it without unbinding your gesture.
- The top row now clearly reads "Gesture to open: ..." so you can see at a glance which gesture opens Glimpse.
- New option to silence the "format not supported" message, for when a reading gesture sometimes opens Glimpse on a PDF or comic (Advanced, off by default).
- Restoring ignored images now lives only in the Gallery's Ignored tab; the separate menu entry was removed.
- Smaller wording tidy-ups (image captions are no longer marked "beta").

**✨ Viewer polish**
- Navigation buttons at the very start or end of your images now keep their normal look instead of turning see-through.
- Alignment fixes so the page dots and the zoom controls sit correctly, including no longer shifting when you zoom in.
- Clearer zoom control dividers in night mode.

## What's new since 1.0.0

**🖼️ A proper gallery, with a place for filtered-out images**
- Two views: your **Gallery** (the images Glimpse keeps) and an **Ignored** pile (everything the filter set aside, plus anything you've ignored yourself). A button at the bottom flips between them.
- **Long-press any image** to move it. Rescue a map the filter wrongly hid, or ignore one you never want to see, without switching to "show all images."

**🔍 Sharper, better zoom**
- Zoomed-in maps and detail now stay crisp instead of going blurry. Glimpse re-loads the image at full resolution when you zoom in.
- Pinch smoothly from best-fit up to 150%, or double-tap to jump in and back out.
- Fixed: panning around a zoomed image could accidentally close Glimpse.

**📖 "Show in Book" now lands on the exact image**
- Previously it dropped you at the top of the chapter. Now it jumps straight to the image you were looking at.

**🌙 Night-mode fixes**
- "Invert in Night Mode" now works the right way round (it was sometimes reversed for some users).
- Fixed a white drawer in dark mode on some Android/Boox devices. It's properly dark now.

**⚡ Less ghosting (e-ink)**
- Opening, closing, and swiping between images no longer cause "ghosts" of the previous image behind, especially noticeable on Kindle and other e-ink screens.
- New option to turn off the drawer's drop-shadow if it causes ghosting on your device or just for cosmetic preference.

**💾 Behind the scenes**
- Glimpse's scan is now stored alongside the book, so it travels with the file between devices.
- A rotated image stays rotated, even after an unexpected shutdown.
