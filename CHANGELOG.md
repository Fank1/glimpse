# Changelog

## Unreleased (in pre-release testing, for the next public release)

Everything below has shipped only in pre-release builds so far. It must be
folded into the notes of the next public release.

**🐛 Fixes**
- Opening the ⋯ menu is snappier again: the button/menu drop shadows now draw only their visible rim instead of a full card-sized buffer (the centre is always hidden under the menu), so the big ⋯-menu shadow no longer costs a full-surface render each open. Looks identical.
- The Glimpse menu's top row now shows the gesture that opens Glimpse even when no book is open (it was wrongly reading "none set" in the file browser).
- When a book has no reference images and you're reviewing the Ignored pile, the gallery's Back button now closes Glimpse instead of surfacing an ignored image as if it were kept.
- A stray long-press on the image (or a bookmarked page) no longer flashes the whole screen and disturbs the drawer's shadow — the press is simply ignored now.

**🎯 A smarter relevance filter (fewer good images wrongly hidden)**
- Maps, family trees, diagrams and charts named as such (`map`, `family-tree`, `diagram`, `chart`, `timeline`, …) are now recognized as reference content, so an endpaper map or a family tree that used to fall just under the size cutoff is kept.
- Illustrated non-fiction gets a gentler filter automatically: when a book already keeps lots of figures (cookbooks, science, how-to), Glimpse lowers the size floor for that book so its smaller diagrams and charts come through too — while novels stay strict, so their decorative bits don't leak in. (Validated across a 200+ book library.)

**🔖 Bookmarked pages in the Gallery**
- Turn on Tools → Glimpse → Include bookmarked pages to also see the pages you've bookmarked (the dogear) in the Gallery, rendered as page thumbnails and marked with a bookmark badge, sitting in reading order among the images. A quick way to keep a reference page (a glossary, a family tree, a map that lives in the text) a swipe away. Tap one to read it full-size, or use Show in Book to jump there.
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
- Reorganized the menu: the top level now keeps just the essentials (Enable, the gesture row, Open Glimpse, Mode, Include Bookmarks in Gallery) plus the Quick Actions, **Settings**, Advanced and Updates sub-menus. Most toggles (nav buttons, zoom controls, invert in night mode, captions, maximum zoom, top-menu-zone) now live under **Settings**, and **Advanced** holds *Disable irrelevant image filtering*, *Suppress "format not supported" notice*, *Disable shadows* and *Rescan this book*.
- New **Settings → Gestures** sub-menu to turn the viewer's touch gestures on or off individually: *Double-tap for maximum zoom*, *Swipe left/right to navigate*, and *Pinch to zoom in/out* (all on by default). Handy if a gesture conflicts with how you hold your device.
- "Include bookmarked pages" is now **Include Bookmarks in Gallery**, sitting directly under Mode — and it's also available as a Quick Action in the viewer's ⋯ menu.
- "Ignore irrelevant images" is now **Disable irrelevant image filtering** (off by default — same behavior, clearer wording), and "Disabled shadows" is now **Disable shadows**.
- Gallery is always available now: it sits at the bottom of the ⋯ menu as its own item (it's the most common jump), so it's no longer one of the configurable Quick Actions. And if you turn *every* Quick Action off, the ⋯ button (which would otherwise open a menu holding only "Gallery") becomes a Gallery button that jumps straight there in one tap.
- Shorter ⋯ menu labels — "Nav Buttons", "Zoom Controls", "Image Captions" (dropped the "Show" prefix) — and the spoiler scope now reads "Mode: Spoiler-free" instead of "Mode: Images up to here".
- Smaller wording tidy-ups: "Rotate 90°" is now "Rotate image" (and it's hidden for bookmarked pages, where it doesn't apply); image captions are no longer marked "beta".

**✨ Viewer polish**
- The Gallery's Shown/Ignored control is now a segmented switcher showing **both** pools and their counts at once ("Gallery [n]" / "Ignored [n]"), with the current one highlighted — tap a segment to switch, instead of a single button that flipped between the two. It now stretches to fill the whole width between the page arrows, so it reads clearly on any screen size.
- The Gallery's Back button is now a compact icon-only button tucked above the forward arrow (bottom-right), freeing the bottom row for the full-width switcher.
- The viewer's active buttons (⋯, the nav arrows, the zoom control, Back/Reset), the Gallery's Shown/Ignored switcher, and the ⋯ pop-up menu now cast a soft downward shadow so they lift off the image; buttons that are greyed out at a dead end stay flat, reinforcing that they're inactive. (Advanced → *Disable shadows* now turns all of these off too, alongside the drawer's shadow.)
- The page-position pill's corners are a touch less rounded, matching the updated design.
- In the Gallery, the page arrows now always show (greyed out on a single page) so the bottom bar's buttons stay put instead of jumping around as you page.
- Long-pressing a Gallery thumbnail now spotlights it — the pressed image gets a bold outline while the others dim — and the action tooltip sits a little higher. (The bold outline used to mark the last image you viewed, a hint most people missed; it's put to better use here.)
- Opening a Gallery full of bookmarked pages is snappier: the page renders that used to trigger a repaint each are now batched into one.
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
