# Changelog

## Unreleased (in pre-release testing, for the next public release)

Everything below has shipped only in pre-release builds so far. Fold it into
the notes of the next public release.

**⚡ Snappier zoom & switching**
- Zooming — pinch, the +/− buttons, and double-tap — is quicker: a zoom step now redraws just the image instead of rebuilding the whole viewer each step.
- Fixed: the viewer's rounded corners no longer square off after a zoom step.
- Flipping to the next or previous image with the arrows or a swipe is quicker: the neighbouring images are decoded ahead of time in the background, so a switch shows the already-prepared image instead of decoding it on the spot, and the switch now redraws just the image area instead of the whole viewer. *(Part of "Fast image switching" — turn it off for the slower, extra-clean redraw.)*

**🐛 Update-checker fixes**
- Checking for updates no longer freezes the device for several seconds when Wi-Fi is up but not fully ready. The check now tests reachability off the UI thread instead of doing a blocking DNS lookup on it, and ignores repeat taps while a check is already running.
- A "DNS error / couldn't reach GitHub" right after connecting is now retried automatically once, so an update check fired the moment Wi-Fi associates no longer fails on the first try.

## 1.3.0

A big update since 1.2.0: bookmarked pages join the Gallery, the image filter got smarter, zoom got more flexible, and the whole viewer feels quicker and more polished. I've also put a lot of focus on customizability, as that's how I want a plugin to be!

**🔖 Your bookmarks, in the Gallery**
- **See your bookmarked pages alongside the images.** Turn on *Include Bookmarks in Gallery* and the pages you've dog-eared show up as thumbnails, in reading order among the pictures. It's a fast way to keep a glossary, a family tree, or a map that lives in the text just a swipe away.
- **Remove a bookmark right from Glimpse.** Long-press it in the Gallery, or use the viewer's ⋯ menu, and it's deleted from the book itself, not just hidden.

**🎯 A smarter filter, with fewer good images wrongly hidden**
- **Maps, family trees, diagrams, charts and timelines** named as such are now recognized as reference content, so an endpaper map or a family tree that used to slip under the size cutoff is kept.
- **Illustrated non-fiction is treated more gently.** When a book already keeps lots of figures (cookbooks, science, how-to), Glimpse automatically relaxes its size floor for that book so smaller diagrams come through too, while novels stay strict so their decorative bits don't leak in. *(Tuned across a 200+ book library.)*

**🔍 Zoom, your way**
- **Choose how far you can zoom**, from 150% up to 400% (*Advanced → Maximum zoom*).
- **Optional on-screen zoom controls**, a small +/fit/− strip for zooming without pinching. The +/− dim at the limits, and the middle button snaps back to a fitted view.

**⚡ Snappier, flashless viewing**
- **Switching between images no longer flashes the whole screen** each time you flip with the arrows or a swipe. *(New Advanced → Fast image switching, on by default. Turn it off if a previous image ever ghosts through on a slower panel.)*
- **Menus and controls open faster**, especially on e-ink, with cleaner shadows that fade in instead of flashing dark first.

**🧭 A tidier, clearer menu**
- **New "Enable Glimpse" switch** turns the whole plugin on or off without unbinding your gesture.
- **New Gestures sub-menu** to turn the viewer's touch gestures on or off individually: *double-tap to zoom*, *swipe to navigate*, *pinch to zoom*. Handy if one conflicts with how you hold your device.
- **The Gallery is now always one tap away** at the bottom of the ⋯ menu.
- **Clearer wording throughout**, with shorter labels and an option to silence the occasional "format not supported" message.

**✨ Viewer polish**
- **A new Gallery / Ignored switcher.** Just tap to switch. It stretches to fill the width, so it reads clearly on any screen.
- **Long-press a thumbnail to spotlight it.** The pressed image stands out while the others dim.
- **Soft shadows lift the active controls** off the image, while greyed-out buttons stay flat so it's obvious they're inactive. *(Advanced → Disable shadows turns all of this off.)*
- **Bookmarked-page thumbnails are cached to disk**, so reopening the Gallery after closing a book shows them instantly instead of re-rendering.
- Assorted alignment and night-mode fixes for the page dots, zoom controls, and captions.

**🐛 Fixes**
- **Auto-rotation works even with the ⋯ menu open.** The menu closes and the viewer re-lays-out for the new orientation.
- **Removing a bookmark clears its dogear from the page immediately**, while Glimpse is still open.
- A stray long-press on an image no longer flashes the whole screen.
- On a book with no reference images, the Gallery's Back button reliably closes Glimpse.

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
