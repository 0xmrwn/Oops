# Changelog

Written by hand for people using Oops, not from commits: list what someone would notice, in plain words. Settings → General → Changelog shows this file: each `## ` heading is a release, newest first, version only (no dates), each `- ` line an entry; **bold** and `code` render. The same section becomes an update's release notes, so rename `## X.Y.Z (unreleased)` to `## X.Y.Z` before building the release.

## 0.3.0 (unreleased)

- In Settings → Fix, the model list has a search field: type part of a model's or a provider's name to find it.
- The drop's words, such as a fix's count and time, are in slightly larger, easier-to-read type, with a little more room after the eyes.
- Settings → General shows what each feature uses under its name: Fix's model and effort, Dictate's speech model and language, or what's left to set up.
- Providers is now in Settings → General, below your features, instead of a tab of its own, and groups your accounts, agents on this Mac and APIs, each with its own way to add one. While none is set up, General says so at the top.
- Settings → Fix → Apps is now Settings → General → Turn off in apps, and lists the apps you dictate in as well as those you fix in. Its row shows how many apps Oops is off in.
- Recent dictations in the menu bar menu shows each one's app icon and, under its words, how long ago you said it, how long you spoke and how many words it has. Settings → Dictate → History shows how long you spoke too. Dictations from before this update show what they have.
- In Settings → Dictate, the ⓘ beside Animation shows the drop's animation you chose moving as it does while you speak, without dictating.

## 0.2.0

- **Dictate is new.** Hold a shortcut and talk, and Oops writes what you said where you're typing; a quick tap keeps it listening until you tap again, and Escape cancels. Turn it on from the card under the menu bar eyes after this update, or in Settings → Dictate. Setting Oops up for the first time now starts by choosing Fix, Dictate or both.
- Dictation happens on your Mac, with a speech model you choose and download in Settings → Dictate, or online with your OpenAI API key. Oops asks for the microphone only once Dictate has a shortcut, and listens only while you dictate.
- When you set Oops up, skipping the Dictate shortcut leaves Dictate off and moves on without the spoken try. Turn it on later in Settings → General.
- Your words can show as you speak, in the drop or greyed out where they'll be written. Clean up is Off, Basic or AI: Basic tidies what you said on your Mac, instantly; AI also has a model rewrite it, and the drop tells you when that didn't work. After a dictation, the drop's Clean up with AI button, or its shortcut, cleans what you just wrote while it's still where Oops wrote it.
- Settings → Dictate also has a vocabulary for names and terms, a speech model per keyboard language, your choice of microphone, and what your Mac's sound does while you dictate: nothing, mute, pause media or lower.
- Dictate keeps a history of what you dictated, on this Mac and never the audio, for 7 days unless you choose 1 day, 30 days or Off. Settings → Dictate → History lists it with search, and each dictation can be copied, inserted where you're typing or deleted. Recent dictations in the menu bar menu has the last five, with Paste last dictation.
- In Settings → Providers, the filter above a long list of models now takes what you type; clicking it did nothing before, and Tab went to the page behind the list. It is a glass search field with a clear button, instead of a boxed one.
- The menu bar menu is grouped by feature: Fix and Dictate each have their own section once both are on, and turning Oops off in the app in front sits with Settings.
- In Settings, the ⓘ beside a setting opens a short explanation with examples when you hover over it, click it or reach it with Tab, instead of a plain tooltip.
- Settings has a new layout. General opens with your shortcut and model at a glance, Fix has a tab of its own, and what was in About is now at the bottom of General. A waiting update shows as a button in the top-right corner.
- In Settings, switching tabs is smoother: the page you leave no longer jumps aside or shrinks before it fades, the new page slides in from its side, and every page opens at its top instead of slightly scrolled. The scroll bar no longer starts under the fade below the tabs.
- In Settings, opening a page inside a tab, such as Customize, About or a provider, and going back is cleaner: the page you leave is gone at once instead of its title fading over the next one, and each of these pages opens at its top.
- In Settings → General, checking for updates no longer makes the row jump, and a new version slides in instead of appearing abruptly.
- A fix no longer pauses for a second when another app has left a modifier key marked as held.
- The welcome window no longer flashes its desktop of app windows, or a black frame, as it opens.
- In setup, the provider list no longer shows API provider alone while Oops looks for ChatGPT and Claude Code: it arrives last, under what was found.
- In setup, the hint on the Accessibility step now moves the way you drag: Oops rises into the list from below.

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
