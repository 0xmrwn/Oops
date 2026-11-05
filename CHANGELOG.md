# Changelog

Written by hand for people using Oops, not from commits: list what someone would notice, in plain words. Settings → About → Changelog shows this file: each `## ` heading is a release, newest first, version only (no dates), each `- ` line an entry; **bold** and `code` render. The same section becomes an update's release notes, so rename `## X.Y.Z (unreleased)` to `## X.Y.Z` before building the release.

## 0.1.0 (unreleased)

- Oops checks for updates once a day. When one is out, Settings → About shows it with what's new: **Update** downloads it, **Relaunch** installs it.
- Connect an API provider during setup: choose a service or local server, pick a model and try a correction before saving.
- One glass-drop character across the app icon, menu bar, welcome and correction capsule. Its eyes sit inside the O on the welcome screen; Settings keeps the app icon beside a plain **Oops** title.
- Correct the draft you're typing in any app with **⌃⌘W** (Control-Command-W): Teams, Claude, Mail, Notes, Obsidian, Safari, Chrome, Zen, Firefox and more. Where an editor hides its text, select the part to fix.
- Changed your mind? Press **⌃⌘W** again to get back what you wrote, and once more to put the fix back, without waiting for the model. It works for five minutes, until you type in the draft. The menu bar's **Restore last correction** and the drop's button restore too; the Restore shortcut is now unset unless you record one in Settings → General.
- Turn Oops off in any app from the menu bar, or in Settings → General → Apps, which lists every app you've corrected in.
- Choose how long a result stays on screen (Settings → General → Show results for): the capsule and the highlight on the fixed words leave together.
- An empty text box says Nothing to fix, and to select your draft if it's there but Oops can't read it (code editors, documents drawn on a canvas).
- Oops waits for input-method compositions it can detect and asks you to finish typing first, and it leaves read-only text unchanged.
- Mentions, attachments and images in a draft stay where they are while the words around them are fixed.
- Corrections follow editors that redraw after an edit and verify the final draft. When Oops can prove an edit landed elsewhere, it undoes that edit and tells you.
- More reliable corrections around images and mentions in Arabic drafts, including Safari composers inside shadow roots and editors that redraw after each edit.
- In code editors that hide the draft, Oops asks you to select text before contacting the model.
- More reliable in Zen: fixes and restores preserve blank paragraphs, including in combobox composers with images or mentions. Selected drafts still use the text box’s own selection.
- Right-to-left drafts (Arabic, Hebrew) with a Latin name, mention or link in them are corrected in Chrome and other Chromium apps, where Oops often declined them before. Chromium shows such text in another order than you typed it, so Oops checks each fix with a copy of your draft.
- Where Firefox or Zen cannot confirm that a paragraph-start fix will keep an empty line, Oops leaves that fix out and says so.
- Copying rich text from Notes on another device (Universal Clipboard) no longer makes every correction fail with a clipboard error.
- Oops stays out of terminals, password managers and password or code fields.
- When the model gets part of a correction wrong, like a line break, a link, a mention or code, Oops keeps the rest of the fixes instead of refusing them all. Answers that rewrite or reply to your text are refused.
- Each fix lands on its own, so mentions, code and formatting between fixes stay exactly as they were.
- A draft with nothing to fix (only links, mentions, code or emoji), or unchanged since it was found clear, gets its answer right away without asking the model.
- The corrected words light up for a moment right where they are, in the app you're typing in, like in Settings → General → Try.
- Correct with ChatGPT, Claude Code or any OpenAI-compatible API, and choose the model and its reasoning effort.
- A quiet capsule next to the text box shows when Oops is working, ends with a check, how many fixes and how long it took, and stays while your pointer is on it.
- When a correction fails, the capsule says why in a few words and offers to try again or open Settings.
- Soft sounds when a correction starts, lands and fails, timed to the capsule's motion. Turn them off in Settings → General.
- The menu bar menu shows whether Oops is ready and with which model, and how many mistakes it has fixed.
- Settings in Liquid Glass: General, Providers and About under one fixed header.
