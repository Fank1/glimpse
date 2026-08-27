# Translation pipeline (maintainer notes)

This file explains how the translation machinery works. It matters only if you
change the machinery. Glimpse is a KOReader plugin, not part of KOReader, so it
has its own translation project instead of riding on KOReader's.

## Files and who owns them

| Path | Owner | Notes |
|---|---|---|
| `templates/glimpse.pot` | repo | Extracted from `main.lua` by `builder/build_l10n.sh`. Never hand-edit. |
| `templates/glimpse-labels.pot`, `-help.pot` | repo | Split from the master by `builder/split_pot.py`. Also generated. |
| `<lang>/labels.po`, `<lang>/help.po` | Crowdin | The translations. See the warning below. |
| `<lang>/glimpse.mo` | build | `msgcat` + `msgfmt` of both `.po`. Gitignored, rebuilt at release. |

`<lang>` uses KOReader's locale codes (`de`, `fr`, `pt_BR`, `zh_CN`), not
Crowdin's. That difference is the most dangerous thing here. See the last
section.

At runtime the plugin loads `l10n/<current language>/glimpse.mo` and merges it
into KOReader's own translation table. Read the comment above `_.loadMO(...)`
near the top of `main.lua`.

## Two components, one catalogue

`split_pot.py` routes each string to one of two component templates:

- `glimpse-labels.pot` — the required set (menus, buttons, dialogs, notices).
- `glimpse-help.pot` — the optional long-press explainers.

A string belongs to help only when every one of its source references sits on a
`help_text =` line. gettext falls back per string, so untranslated help shows in
English. A language ships as useful once its labels are done.

`build_l10n.sh` compiles both `.po` into a single `<lang>/glimpse.mo`, because
gettext looks up one catalogue per language.

## Never hand-edit a .po in git

Crowdin owns `l10n/<lang>/*.po`. Set the integration option "Import new
translations from repository" to OFF, so Crowdin does not read `.po` changes
made in git. A hand-edited `.po`, even one merged through a pull request, is
overwritten by the next sync.

If someone sends a translation as a pull request, do not merge it. Ask the
person to submit it in Crowdin, or import it there yourself.

The repo owns the other direction: the `.pot` templates are generated here, and
"Push Sources" is OFF, so Crowdin cannot overwrite them. Sources flow repo →
Crowdin. Translations flow Crowdin → repo.

## The initial machine-translation seed

`builder/fill_po.py` writes the first `.po` from an AI translation. Use it to
seed a language before Crowdin exists. After the Crowdin project connects,
Crowdin owns the `.po`. Do not run `fill_po.py` again over Crowdin's work.

## Stop line numbers from churning the repo

`xgettext` stamps `#: main.lua:1642` beside every string. Those line numbers
shift on every release. A shifted `.pot` looks modified to Crowdin, so Crowdin
re-syncs, regenerates every language, and opens a pull request with no
translation work in it.

The master `glimpse.pot` keeps its locations, because `split_pot.py` needs them
to route help versus labels. `split_pot.py` strips the locations from the two
component templates, which are the files Crowdin syncs. `build_l10n.sh` runs
`msgmerge --no-location`, so the `.po` also stop carrying them. A pure line
shift is then a no-op, while a real string change still comes through.

## The locale-directory trap

The runtime loads `l10n/<KOReader current_lang>/glimpse.mo`. A directory named
anything KOReader does not use builds a `.mo` that is never loaded, with no
error and an untranslated UI. Crowdin's default `%locale_with_underscore%`
emits `de_DE` where KOReader wants `de`, so `crowdin.yml` carries an explicit
`languages_mapping`. `build_l10n.sh` rejects any `l10n/<dir>` that is not in
`plugin/l10n/LOCALES`.

## Project settings that are not in crowdin.yml

`crowdin.yml` governs file mapping only. Set these in the Crowdin web UI (see
`../../docs/CROWDIN-SETUP.md`):

- Skip untranslated strings — ON.
- Push Sources — OFF.
- Import new translations from repository — OFF.
