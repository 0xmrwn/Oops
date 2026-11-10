# Changelog

Written by hand for people using Oops, not from commits: list what someone would notice, in plain words. Settings → About → Changelog shows this file: each `## ` heading is a release, newest first, version only (no dates), each `- ` line an entry; **bold** and `code` render. The same section becomes an update's release notes, so rename `## X.Y.Z (unreleased)` to `## X.Y.Z` before building the release.

## 0.1.4

- Fixing a word inside or next to bold, italic or underlined text keeps that formatting as it was, instead of dropping it or spreading it onto the fix.
- In setup, Tab now shows where it is on Change shortcut, and opening or leaving the API setup from the keyboard keeps your place instead of jumping to Skip. The API setup's fields are easier to read over the bright end of the wallpaper.

## 0.1.3

- Apps that install a downloaded disk image for you, rather than you dragging Oops to Applications, no longer refuse Oops.

## 0.1.2

- Oops never asks for your login password. When it can't read a saved sign-in or API key, Settings asks you to sign in or enter the key again.
- Settings → About shows the version without the build number.

## 0.1.1

- Correcting with ChatGPT no longer makes Oops quit.

## 0.1.0

- Fix the draft you're typing in any app with one shortcut, chosen during setup: Slack, Teams, Notion, Mail, Notes, Obsidian, Claude, Safari, Chrome, Zen, Firefox and more. Only the mistakes change; mentions, links, code, images and formatting stay as they are.
- Use the ChatGPT or Claude subscription you already pay for, with no API key: sign in with ChatGPT or connect Claude Code. Any OpenAI-compatible API works too, including local servers, with a choice of model and reasoning effort.
- Press the shortcut again on the same draft within five minutes to restore your original text, and once more to reapply the fix.
- A small glass drop beside the text box shows progress and the number of fixes; the corrected words briefly light up in place. Sounds can be turned off in Settings → General.
- Right-to-left drafts, such as Arabic and Persian, are supported, including ones that mix in Latin names or links.
- When a draft can't be read, Oops says so and asks you to select the text. It stays out of password fields, password managers and terminals.
- Turn Oops off for any app from the menu bar or Settings → General → Apps.
- Updates are checked daily and installed from Settings → About.
