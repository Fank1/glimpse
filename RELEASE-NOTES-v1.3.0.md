# Glimpse 1.3.0

A big update since 1.2.0: bookmarked pages join the Gallery, the image filter got smarter, zoom got more flexible, and the whole viewer feels quicker and more polished. I've also put a lot of focus on customizability, as that's how I want a plugin to be! 

Now, the Bookmarks feature is not meant to replace the vanilla Bookmarks functionality in KOReader. It's a way of easily storing references that you want to look at later! To add a bookmark in your book, configure your Gestures and look for "Toggle bookmark".

As always, please feedback and preferably post them in Issues on Github. And yes, localization is coming, it's just a hazzle! 

---

## 🔖 Your bookmarks, in the Gallery

- **See your bookmarked pages alongside the images.** Turn on *Include Bookmarks in Gallery* and the pages you've dog-eared show up as thumbnails, in reading order among the pictures. It's a fast way to keep a glossary, a family tree, or a map that lives in the text just a swipe away.
- **Remove a bookmark right from Glimpse.** Long-press it in the Gallery, or use the viewer's ⋯ menu, and it's deleted from the book itself, not just hidden.

## 🎯 A smarter filter, with fewer good images wrongly hidden

- **Maps, family trees, diagrams, charts and timelines** named as such are now recognized as reference content, so an endpaper map or a family tree that used to slip under the size cutoff is kept.
- **Illustrated non-fiction is treated more gently.** When a book already keeps lots of figures (cookbooks, science, how-to), Glimpse automatically relaxes its size floor for that book so smaller diagrams come through too, while novels stay strict so their decorative bits don't leak in. *(Tuned across a 200+ book library.)*

## 🔍 Zoom, your way

- **Choose how far you can zoom**, from 150% up to 400% (*Advanced → Maximum zoom*).
- **Optional on-screen zoom controls**, a small +/fit/− strip for zooming without pinching. The +/− dim at the limits, and the middle button snaps back to a fitted view.

## ⚡ Snappier, flashless viewing

- **Switching between images no longer flashes the whole screen** each time you flip with the arrows or a swipe. *(New Advanced → Fast image switching, on by default. Turn it off if a previous image ever ghosts through on a slower panel.)*
- **Menus and controls open faster**, especially on e-ink, with cleaner shadows that fade in instead of flashing dark first.

## 🧭 A tidier, clearer menu

- **New "Enable Glimpse" switch** turns the whole plugin on or off without unbinding your gesture.
- **New Gestures sub-menu** to turn the viewer's touch gestures on or off individually: *double-tap to zoom*, *swipe to navigate*, *pinch to zoom*. Handy if one conflicts with how you hold your device.
- **The Gallery is now always one tap away** at the bottom of the ⋯ menu.
- **Clearer wording throughout**, with shorter labels and an option to silence the occasional "format not supported" message.

## ✨ Viewer polish

- **A new Gallery / Ignored switcher.** Just tap to switch. It stretches to fill the width, so it reads clearly on any screen.
- **Bookmarked-page thumbnails are cached to disk**, so reopening the Gallery after closing a book shows them instantly instead of re-rendering.
- Assorted alignment and night-mode fixes for the page dots, zoom controls, and captions.

## 🐛 Fixes

- **Auto-rotation works even with the ⋯ menu open.** The menu closes and the viewer re-lays-out for the new orientation.
- **Removing a bookmark clears its dogear from the page immediately**, while Glimpse is still open.
- A stray long-press on an image no longer flashes the whole screen.
- On a book with no reference images, the Gallery's Back button reliably closes Glimpse.
