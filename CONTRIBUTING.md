# Helping translate Glimpse

Glimpse can speak your language, and you can help without any programming.

## Translate on Crowdin

Glimpse is translated here:

**https://crowdin.com/project/glimpse-plugin**

Sign in, pick your language, and start typing. Nothing to install, no files to
send. Your work is collected automatically and ships with the next version.

### The drafts were written by a computer. Please fix them

Every language starts from an AI first draft. Some of it is fine, some is stiff,
some is wrong. Reading a line and fixing what sounds off is much faster than
writing it from scratch. **Even ten fixed lines help.** You do not have to
finish anything, and anything you skip stays in English.

Please do not paste in machine translation you have not read yourself. A clearly
wrong sentence is worse for a reader than an English one.

### Start with the short texts

There are two sets:

- **labels** – the short menu items, buttons and messages. Start here.
- **help** – the longer explanations shown when you hold a menu item down.

Doing only **labels** already makes Glimpse fully usable in your language.

### Two rules that matter

1. **Keep `%1` and `%2` exactly as they are.** These are slots that Glimpse
   fills with a number or a word (for example `Page %1`). You may move a slot
   within the sentence, but never delete it or add new ones. Crowdin warns you
   if one goes missing.
2. **Match KOReader's own wording.** Glimpse lives inside KOReader's menus, so
   common words like *Cancel*, *Settings* and *Close* should read the same way
   KOReader already says them in your language.

If your language is missing, open an issue and it will be added. You do not need
anyone's approval: what you write goes out in the next version.

---

Translations are contributed under Glimpse's licence, **AGPL-3.0-or-later**, the
same one KOReader uses. That is what lets a translation ship inside the plugin.

How the `.po` files are built and synced is documented separately in
[plugin/l10n/README.md](plugin/l10n/README.md). You do not need any of it to
translate.
