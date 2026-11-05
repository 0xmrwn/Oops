# Editor compatibility

Oops needs an editable field exposed through macOS Accessibility. Support depends
on the editor inside an app, so two fields in the same app can behave differently.

## Tested apps

These checks ran on macOS 27 with a fixed correction response. They cover reading,
applying, restoring and highlighting text, without calling a model. They do not
measure model quality or establish compatibility with every app or OS version.

| App and field | Last checked (2026) | Result |
| --- | --- | --- |
| TextEdit, Notes | 2 November | Correction, restore and highlights passed. |
| Mail message body | 2 November | Correction, restore and highlights passed. |
| Safari and Chrome: textarea and contenteditable | 2 November | Correction, restore and highlights passed. |
| Zen: textarea and contenteditable | 2 November | Correction, restore and highlights passed. See Gecko limits below. |
| Obsidian note body | 2 November | Correction, restore and highlights passed. |
| Microsoft Teams composer | 25 October | Correction, restore and highlights passed. |
| Claude composer | 24 October | Correction, restore and highlights checked manually. |

Notion did not expose an editable field in the last check. Messages, Codex, Slack
and VS Code have not been verified in this set. An app missing from the table may
still work if its editor exposes the required text and selection information.

## Capture and recovery

Oops first reads the field's text and selection. Text markers provide another
route when the field's value is missing or does not account for inline objects.
If neither route works, Oops can copy selected text through the editor.

Copy-only editors require a selection. They have no restore or highlights because
Oops cannot read back and confirm the corrected draft. A partial rich-text
selection is refused when replacement could lose an attachment or mention.

Chromium editors can take about two seconds to expose text geometry after Oops
enables accessibility. Gecko editors can initially expose the page instead of the
focused field; changing focus away and back can help.

## Known limits

- Some Gecko selections containing chips or images expose inconsistent selection
  and copied text. Oops refuses edits it cannot verify. Some read-only Gecko
  fields report themselves as editable, so a model request can occur before
  replacement fails.
- Some Slate editors hosted in Electron keep a selection that Oops cannot place
  reliably. Correction can be refused in those fields.
- Finish input-method composition before invoking Oops. Some Catalyst, native
  single-line and Qt fields hide their in-progress composition from Accessibility;
  Oops cannot reliably protect text it cannot detect. Composition exposed by the
  editor is refused while active.
- Terminal apps, password managers, secure fields and sensitive single-line
  inputs are excluded. Apps can also be disabled in Settings.

Typing or changing focus during correction can invalidate the captured draft.
Oops checks before applying edits and reports uncertain or partial results
without blindly repeating a paste.
