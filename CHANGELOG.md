# Changelog

## Unreleased

**New formats**
- FB2 (.fb2) books are now supported. Glimpse reads the embedded images and maps each one to its chapter for spoiler scope.
- MOBI (.mobi, .prc) books are now supported. Glimpse reads the embedded images and skips the cover. A MOBI holds the whole book as one HTML document, so Glimpse cannot tell which chapter an image belongs to.
- On a MOBI the mode is locked to "All images". The Mode row in the ⋯ menu and the Mode setting are greyed out, and a tap on the row explains why. Your setting is kept, and an EPUB gets it back.

**Compact panel**
- A new Quick Action shrinks the panel to a small free-floating card that sits over the page. The ⋯ menu row says where the tap goes: "Switch to Compact", then "Switch to Large". Drag the card by the grip in its top-right corner. Glimpse remembers where you put it, and puts it back next time.
- The same choice is in Settings, under Layout, as "Panel Size: Large / Compact". Pick a size there while Glimpse is open and the panel changes at once.
- The card keeps the image, the dot indicator, the ⋯ menu, and the zoom controls and mini map when those are on. It hides the captions, the bookmark label, the navigation buttons and the reset button. Zoom in and the dots go too, so the image gets the whole card. Double-tap still resets the zoom. Swipe still changes image.
- The chrome on the card is drawn flat with a white outline instead of a drop shadow, so it stays readable over the image. The mini map sits in the bottom-left corner, the dot indicator on the bottom edge, and the zoom controls stack onto the ⋯ button in the bottom-right. Each one shares the card's own border, and the zoom controls join the ⋯ with the same faint hairline that separates + from −.
- The card's mini map stays a small badge in the corner. A wide image shrinks to fit it. Its top-right corner now carries the same slight rounding as the design.
- **In night mode the card gets its border back.** The four straight edges were painted black on a black page, so the card had no visible frame: only its four corner arcs showed, as if it were torn. The frame is now an unbroken white line, the way it is in day mode.
- The card's night border is also the same width as its day border. It used to be a hairline, half as thick, which broke up around the rounded corners: the curve thinned to a single pixel and read as a gap.
- The card's shadow reaches about 60% further in night mode. A shadow can only darken, so on a dark page the reach that lifts the card off a white page hardly registers. The wider field gives the card the same separation from the text around it. Day mode is unchanged.
- The dot indicator now sits on the middle of the card's bottom edge. It used to centre itself in the space left over beside the ⋯ button, which pushed it off to the left.
- On the card, the numbered indicator now matches the dot indicator: the same colours, the same height, and the same docking on the bottom border. In night mode both are white. The large panel is unchanged, where the numbered indicator stays light on a dark page so it does not pull the eye.

**Mini map**
- The rectangle that marks where you are in the image now has slightly rounded corners, in both the large panel and the compact card.
- Nav Buttons and Image Captions are dimmed in the ⋯ menu while the compact panel is on, because the card cannot show them.
- Settings → Gestures applies to the large panel only. The compact panel always keeps swipe, pinch and double-tap on, because it hides the navigation buttons and the reset button.
- Opening the Gallery restores the large panel, so the thumbnails stay usable. Leaving the Gallery brings the card back.

**Maximum zoom**
- The Maximum zoom setting now has a Custom option. Enter any value from 100% to 1000%, in place of the fixed presets. A very high value helps low-resolution images fill the screen.
- **Zooming in is much quicker, and it no longer slows down the further you go.** Each step used to rebuild the whole image at the new size and then show a screen-sized piece of it, so the work grew with the square of the zoom: on a 1920×2778 image the fourth step built a 109-megapixel picture to show 1.3 of them, and took 480 ms. Glimpse now builds only the part you can see. The same step takes 9 ms, and every step costs the same however far in you are.
- You can now zoom all the way to the value you set. The old path had to stop early to stay inside the memory limit, which also left the "+" button looking active when the image could not grow further. Both are gone: "+" greys out exactly at your Maximum zoom.

## 1.5.1

**Gallery**
- Wide top/bottom layouts now show 4 columns instead of 3, so more images fit at once.
- Thumbnails line up on the left with the heading, and the page number is now the prominent label (the image count moved to the corner).

**Viewer**
- The mini map no longer stretches across the screen on wide landscape images. It stays the height of the zoom controls, with the image letterboxed inside.

**New setting**
- Numbered indicator instead of dots: shows a compact "3 / 42" counter in place of the row of dots, handy when a book has so many images that the dots get very wide.

**Changed setting**
- Respect KOReader top menu activation (renamed, moved to Advanced): the top-edge tap opens KOReader's menu only when KOReader itself is set to open its menu on a tap.

**Other**
- Settings reorganised into clearer groups.

## 1.5.0

**↔️ Choose where Glimpse opens (Settings → Layout)**
- **Pick a side, or a top/bottom band.** The Layout modal now has two settings: *Portrait Position* (Side · Bottom · Top) and *Preferred Alignment* (Left · Right). In portrait you can have the panel slide in from the left or right edge, or open as a band across the top or bottom half of the screen. In landscape it always uses your preferred side, so a rotate never leaves it stuck top or bottom.
- The whole drawer adapts to wherever it opens – its rounded edge, gradient shadow, border and the ‹/› arrows all sit on the right sides for that placement. Also available as a Quick Action in the ⋯ menu.
- **A live preview in the Layout dialog** shows a portrait and a landscape mockup that update as you change the settings, so you can see where the panel lands before you apply.

**🗺️ Mini map (Settings → Show Mini Map)**
- While zoomed in, a small overview of the image appears in the corner with a rectangle marking the part you are viewing. The rectangle shrinks as you zoom further. Tap anywhere on the map to jump straight there, an alternative to panning.
- It docks to the zoom controls when those are on, and stands on its own (all corners rounded) when they are off. Its shape follows the image area, so a top/bottom band gets a wide map and a side panel a tall one. Hidden at the fitted view. Off by default; also available as a Quick Action in the ⋯ menu.

**🔁 Looping navigation (Settings → Navigation Loops Around)**
- Turn it on and the ‹ › buttons and swipes wrap around: Next on the last image jumps back to the first, and Previous on the first goes to the last, so the arrows never grey out at the ends. The Gallery pages wrap the same way. Off by default.

**✨ Small polish**
- Bookmarked items in the dots indicator now show a tiny bookmark glyph instead of a plain dot, so you can tell a bookmarked page from an image at a glance.
- The image caption now matches the bookmark pill: a floating white rounded pill with a soft grey border, keeping its small text.
- Fixed: on a top band the ⋯/nav row now has the same bottom margin as the side margins, and the bookmark pill stays left-aligned on a right-side panel.
- Fixed: on a top band the bottom row of controls now clears the drawer's rounded corners, and the ⋯ menu opens centred on screen instead of running off the panel and over the page.
- Fixed: on a page that is both bookmarked and captioned, the caption now sits just below the bookmark label instead of being hidden behind it.
- Fixed: toggling a checkbox in the ⋯ menu could leave the ⋯ button stuck in its dark pressed state after the menu closed, when the toggle shifted the button's position.

**🌍 Glimpse now speaks your language**
- The whole interface can be translated. This release ships an initial machine translation for 22 languages (German, French, Spanish, Italian, Portuguese, Dutch, Swedish, Danish, Norwegian, Finnish, Polish, Czech, Romanian, Russian, Ukrainian, Greek, Turkish, Chinese, Japanese, Korean), loaded automatically to match KOReader's language. Untranslated text falls back to English.
- Translations are managed on Crowdin, so anyone can help improve them or add a language.

**✅ Toggle several settings without the menu closing**
- The checkbox rows in the ⋯ menu (Nav Buttons, Zoom Controls, Image Captions, Invert in Night Mode) now apply instantly and keep the menu open, so you can flip several in one go. Action rows still close the menu as before.

**⚡ Snappier zoom & switching**
- Zooming — pinch, the +/− buttons, and double-tap — is quicker: a zoom step now redraws just the image instead of rebuilding the whole viewer each step.
- Panning a zoomed image with the mini map on is much smoother: the map's dimmed overview is now prepared once and reused on each pan instead of being redrawn pixel-by-pixel, so a pan redraws in well under a millisecond instead of tens of milliseconds.
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
