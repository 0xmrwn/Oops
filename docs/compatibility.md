# Editor compatibility

Oops doesn't support apps one by one. A text box is always built from one of a small number of technologies: a web editing engine running in a browser engine, or a native text toolkit. Oops is tested against those technologies directly. Any app built on a covered engine gets the same behaviour, including apps that don't exist yet.

## How it's tested

The [reliability bake-off](../fixtures/bakeoff/README.md) builds real editors from each technology and runs Oops against them. The web editors are the real engines, pinned to exact versions, not imitations. The native editors are small apps built with each toolkit.

- **15 web engines × 5 browser engines and app shells**: every engine runs in every shell.
- **11 native toolkit configurations**, across AppKit, SwiftUI, Mac Catalyst, Qt, Swing and custom-drawn text.
- **8 dimensions crossed pairwise**: layout, content, app behaviour, zoom and direction, what's being corrected, and how the editor is embedded in the page. Every pair of values meets in at least one case.
- **An edge set** of fields Oops must refuse: password fields, read-only text, canvas-drawn editors and secure native fields.

That makes 254 cases. Each one is graded on what the **editor itself** ends up holding (ProseMirror's document, Lexical's state, the SwiftUI binding), not on what Accessibility reports. A correction only counts if the app accepted it.

A case that should work is graded on five stages:

| Stage | Passes when |
| --- | --- |
| Capture | Oops read exactly the draft or the selection. |
| Apply | The editor's own model holds the corrected text, with mentions and images intact. |
| Restore | Pressing again brings back the original text and its mentions and images. |
| Highlight | The corrected words light up inside the field. |
| Placement | The progress drop sits next to the text box, not the window or the screen. |

A case that should refuse is graded on three: no model was asked, nothing changed, and the message names the reason.

No model is called. A stub returns the corrected draft, so the benchmark measures editor reliability alone. Each case also checks that its own setup is right before Oops runs: a broken fixture is reported as such and never counted.

## Results

**245 of 250 graded cases pass.** All five failures are in Zen (Gecko), and each one leaves the draft unchanged. Two Mac Catalyst cases are out of scope (see [known limits](#known-limits)). Two WebKit cases can't run, because a cross-origin frame there can't start an input-method composition without a person typing.

The first run of the same set passed 153 of 252. The fixes were made by mechanism: what each failure revealed about how an engine exposes its text, never by special-casing a test or loosening what a case expects. Two further sets of about 95 combinations each were generated the same way and kept out of the repository. They score the same: 93 of 95 and 91 of 93.

### Web engines

✓ means every case for that engine in that shell passed.

| Engine | Apps built on it | Safari | WebKit view | Chrome | Zen | Electron |
| --- | --- | :-: | :-: | :-: | :-: | :-: |
| ProseMirror (Tiptap 3.31) | ChatGPT and Claude on the web, Linear, GitLab, Substack, Le Chat, Grok | ✓ | ✓ | ✓ | ✓ | ✓ |
| Lexical 0.52 | Perplexity, Ghost | ✓ | ✓ | ✓ | 2/3 | ✓ |
| Slate 0.133 | Discord, Grafana | ✓ | ✓ | ✓ | ✓ | ✓ |
| Quill 2.0 | Gemini; Slack's composer reportedly began as a Quill fork | ✓ | ✓ | ✓ | ✓ | ✓ |
| Draft.js 0.11 | X, older CMS fields | ✓ | ✓ | ✓ | ✓ | ✓ |
| CKEditor 5 (v49) | Microsoft Teams, CMS and helpdesk editors | ✓ | ✓ | ✓ | 1/2 | ✓ |
| TinyMCE 8.9 | WordPress's classic editor, CMS and LMS forms | ✓ | ✓ | ✓ | ✓ | ✓ |
| CodeMirror 6 | Obsidian, Replit, GitHub's file editor | ✓ | ✓ | ✓ | ✓ | ✓ |
| Monaco 0.57 | VS Code, Cursor, Codespaces, Azure DevOps | ✓ | ✓ | ✓ | ✓ | ✓ |
| RoosterJS 9.60 | Proton Mail | ✓ | ✓ | ✓ | ✓ | ✓ |
| Trix 2.1 | Basecamp, HEY, Rails Action Text | ✓ | ✓ | ✓ | ✓ | ✓ |
| Block editors | Notion, WordPress (Gutenberg), Craft | ✓ | ✓ | ✓ | 1/2 | ✓ |
| contenteditable | Gmail, most in-house composers | ✓ | ✓ | ✓ | 1/2 | ✓ |
| textarea | GitHub, Qwen, HuggingChat, most forms | ✓ | ✓ | ✓ | ✓ | ✓ |
| input | Search boxes, single-line chat inputs | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Total** | | **34/34** | **43/43** | **36/36** | **30/35** | **35/35** |

The totals include the edge set: password fields, read-only text, and canvas-drawn editors such as Google Docs, in every shell.

The shells stand for every app built the same way:

| Shell | Stands for |
| --- | --- |
| Safari 27 | Safari |
| WebKit view | Mail's composer, Microsoft Teams, Tauri apps, any app hosting a WKWebView |
| Chrome 156 | Chrome, and Arc, Edge, Brave and other Chromium browsers, which share its accessibility code |
| Zen 1.24 | Firefox and other Gecko browsers |
| Electron 44.7 | Slack, Discord, Notion, Linear, Obsidian, Signal, VS Code, Figma, Claude |

Monaco draws its text instead of exposing it, so Oops corrects it through copy and paste on a selection. Without a selection, Oops asks for one. Canvas editors such as Google Docs work the same way.

### Native toolkits

| Toolkit | Apps built on it | Result |
| --- | --- | :-: |
| AppKit NSTextView, TextKit 1 and TextKit 2 | Notes, TextEdit, most native composers | 12/12 |
| AppKit NSTextField | Search boxes, forms, one-line chat inputs | 5/5 |
| SwiftUI TextEditor, growing TextField, rich-text TextEditor | SwiftUI chat and note apps | 18/18 |
| Mac Catalyst UITextView and UITextField | Messages, WhatsApp | 9/9 |
| Qt (QTextEdit) | Telegram Desktop, OBS, Anki | 6/6 |
| Swing (JTextArea) | JetBrains IDEs' commit and comment fields | 6/6 |
| Custom-drawn text | Zed and other GPU-drawn editors | 6/6 |
| Secure and read-only fields | Password prompts in every toolkit, read-only text | 5/5 |

Custom-drawn editors expose no text, so Oops corrects them through copy and paste on a selection, as it does Monaco. The two Catalyst cases left out are input-method compositions that Catalyst hides from Accessibility (see [known limits](#known-limits)).

### Across every dimension

The engines above are crossed with the situations a draft is really written in. Pass rates for each value, web and native together:

| Dimension | Results |
| --- | --- |
| Layout | Chat composer 101/101 · thread reply 25/25 · side panel 25/26 · modal 34/35 · nested scroll 23/24 · full-page document 37/39 |
| Content | Plain text 165/166 · mentions 54/56 · inline images and emoji 26/28 |
| App behaviour | None 128/131 · paste interception 26/28 · re-render after every edit 25/25 · slash menu open 28/28 · IME composition 23/23 · combobox role 15/15 |
| Presentation | Normal 150/152 · 150% zoom 54/56 · right-to-left Arabic with Latin names and links 41/42 |
| Target | Whole draft 139/139 · a selection 62/67 · several paragraphs 44/44 |
| Embedding (web) | In the page 115/116 · same-origin iframe 25/25 · cross-origin iframe 21/22 · shadow DOM 17/20 |

## Real apps

On top of the benchmark, ten real fields pass all five stages: TextEdit, Notes, the Mail message body, an Obsidian note, and a textarea and a contenteditable in each of Safari, Chrome and Zen. The Microsoft Teams and Claude composers were checked by hand, and so was a Notion page body in Notion's desktop app: correction, restore, reapplying the fix and highlights.

Slack, Messages and VS Code haven't been checked as real apps. Their engines and shells are all in the benchmark.

## Capture and recovery

Oops first reads the field's text and selection. Text markers are a second route when the field's value is missing or leaves out inline objects. If neither route works, Oops can copy selected text through the editor.

Editors that only allow copying need a selection. They have no restore or highlights, because Oops can't read the corrected draft back to confirm it. A partial rich-text selection is refused when replacing it could lose an attachment or a mention.

Chromium editors can take about two seconds to expose text positions after Oops turns their accessibility on. Gecko editors can expose the whole page at first instead of the focused field; moving focus away and back helps.

## Known limits

- **Gecko read-only fields.** Some report themselves as editable, so a model request can happen before replacing the text fails. The draft stays as it was.
- **Gecko selections that include mentions or images.** These can expose selection and copied text that don't agree. Oops refuses edits it can't verify rather than guessing.
- **Slate in Electron, with a combobox role.** Some of these keep their own selection, which Oops can't place reliably. Correction can be refused there.
- **Input-method composition.** Finish composing before invoking Oops. Some Catalyst, native single-line and Qt fields hide an in-progress composition from Accessibility, so Oops can't protect text it can't see. A composition the editor does expose is refused while it's active.
- **Excluded by design.** Terminals, password managers, secure fields and sensitive single-line inputs. Any app can also be turned off from the menu bar or in Settings.

Typing or changing focus during a correction can invalidate the captured draft. Oops checks again before applying, and reports an uncertain or partial result rather than pasting again blindly.
