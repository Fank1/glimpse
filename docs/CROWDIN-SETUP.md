# Crowdin setup for Glimpse (one-time)

The repo side is ready: `crowdin.yml` at the root, the two source templates
under `plugin/l10n/templates/`, and the build pipeline. These steps set up the
Crowdin project and its GitHub integration. Do them once, in the Crowdin web UI.

The goal of the settings below is the same one you asked for: Crowdin opens a
pull request only when a translator actually changes a translation, never for a
source-line shift or a routine re-sync.

## 1. Create the project

1. Create a new Crowdin project named `Glimpse`.
2. Set the source language to English.
3. Set the license to AGPL-3.0-or-later, to match the plugin.

## 2. Add the target languages

Add the languages Glimpse ships. These are KOReader's own locales. The
`languages_mapping` block in `crowdin.yml` already maps every Crowdin language
id to KOReader's directory name (for example `de_DE` → `de`), so add the
languages and leave the mapping to the file.

## 3. Connect the GitHub integration

1. In the project, open Integrations and add GitHub.
2. Authorize it and select the `Fank1/glimpse` repository.
3. Set the base branch to `main`.
4. Set the service branch name to `l10n_main`. Crowdin commits translations to
   this branch and opens its pull request from it.

## 4. Integration settings (the important part)

Set each of these:

- **Push Sources — OFF.** The repo generates the `.pot` templates. Crowdin must
  never overwrite them.
- **Import new translations from repository — OFF.** Crowdin owns the `.po`. A
  hand-edited `.po` in git is ignored, and the next sync overwrites it.
- **Skip untranslated strings — ON.** Without it Crowdin fills an untranslated
  string with the English source, so a language at 5% looks complete. The
  runtime expects gettext's per-string fallback instead, which needs the string
  to be absent.

The source templates already carry no `#:` line-number references (stripped by
`builder/split_pot.py`), so a code change that only shifts line numbers does not
look like a source change. That, plus "Push Sources OFF", is what stops the
empty churn pull requests.

## 5. Credentials

Never put credentials in `crowdin.yml`. It is committed to a public repo.

- The GitHub integration authenticates through the Crowdin web UI. It needs no
  secret in the repo.
- For the optional local CLI (`crowdin` command), export
  `CROWDIN_PROJECT_ID` and `CROWDIN_PERSONAL_TOKEN` in your shell. Store the
  token in the OS keychain. Never pass it on a command line.

## 6. Release flow

Crowdin commits to `l10n_main` continuously. Merge it only when you cut a
release, so nothing lands unreviewed mid-cycle:

```
git merge origin/l10n_main       # bring in new translations
python3 builder/check_po.py      # placeholders, spacing, plural counts
./release.sh <version>           # stage.sh compiles .po -> .mo into the zip
```

If you seeded `.po` locally with `builder/fill_po.py`, delete those files
before the first merge from `l10n_main`, or git refuses to overwrite them.
