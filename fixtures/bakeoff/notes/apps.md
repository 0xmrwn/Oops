# What the installed apps show

Inspected on 25 October 2026 on the development Mac, through Oops's own probe:

```bash
fixtures/composer-lab/tools/trigger app focus <bundle>
fixtures/composer-lab/tools/trigger app attributes <bundle>
fixtures/composer-lab/tools/trigger app outline <bundle>
```

For each app, the probe focused the largest editable field in the front window, then listed its
attributes and the window's tree. It kept only roles, sizes and text lengths, never what a field
held. Nothing was typed, and apps that weren't already running were quit afterwards.

| App | Shell | Focused field | What it means for the set |
|---|---|---|---|
| Notion | Electron | AXTextArea, subrole AXApplicationGroup. Value 511 characters, text markers 461 | The page is one text area whose value and marker text differ: block separators count differently. Document layout, multiline target. |
| Microsoft Teams | web view | AXTextArea with text markers and `AXValueAutofillAvailable`. An empty composer reports its prompt as text | Bottom composer and thread. The placeholder-as-value fix is in Oops already. |
| Messages | Catalyst | AXTextField. `AXValue` returns an error when the composer is empty, and a placeholder is set | Catalyst field cases. A paste is the reliable write. |
| Notes | AppKit | AXTextArea with settable value and selection, and `AXReplaceRangeWithText` | TextKit cases (Notes is in the compat table). |
| Zed | GPUI | Five nodes: the window and its buttons. No text element | The custom-drawn view: Accessibility sees a group. Copy with a selection, refuse without. |
| Linear | Electron | Only Chromium's basic tree (36 nodes), and no editable field on the issue list | Electron's tree is dormant until a client sets `AXManualAccessibility`, as Oops does at capture. |
| Obsidian | Electron | 756 nodes, but no editable field in the basic tree | CodeMirror 6 in Electron. Oops wakes the full tree first. |
| Anytype | Electron | 264 nodes, no editable field in the basic tree | Same as Obsidian. |
| Discord | Electron | No focused window while it updated on launch | Not probed. Slate in Electron, from sources. |

## Left alone

- **ChatGPT.app** here is the Codex app, which other sessions drive.
- **Claude** is the window running this work.
- **Mail and Outlook**: a compose window saves a draft to the account.
- **Word and Pages**: they open on a template chooser, and closing a new document asks to save it.
- **Arc**: shares Chrome's engine.
- **Slack, VS Code, Signal, Telegram**: not installed. Sources cover them (see engines.md and
  shells.md).

## Web apps

Two passes, both without an account:

1. **Bundles.** Each app's public JavaScript (the page, then up to 400 of its scripts) was searched
   for engine signatures, and each hit was read in context. This shows the engine even where the
   editor only loads after sign-in.
2. **Live pages.** A throwaway Chrome profile under `.build/`, launched in the background (headful,
   never focused, since some sites turn headless browsers away), was read over the DevTools Protocol.
   An earlier headless pass found the same fields on every page both reached. For every
   top-level editable, through shadow roots and same-origin iframes, it recorded:
   - tag, role, ARIA label, wrappers (custom elements, frames), children;
   - non-editable atoms and zero-width characters.

   On public engine demos only, it also checked whether the engine takes a paste over (a synthetic
   `paste` event) and keeps a selection set from outside. Nothing was typed into a real composer,
   sent or submitted. The profile was deleted afterwards.

### Live: AI chat composers

| Composer | Field | Notes |
|---|---|---|
| Gemini | Quill `div.ql-editor[role=textbox][aria-multiline]` | inside `rich-textarea` > `input-area-v2` > `input-container` > `chat-window` custom elements (light DOM) |
| Perplexity | Lexical `div#ask-input[role=textbox]` | one `<p>` per line |
| Grok | Tiptap `div.tiptap.ProseMirror[role=combobox]` | **combobox**, not textbox, plus a hidden one-character textarea |
| Mistral Le Chat | ProseMirror `div.ProseMirror` | no role set |
| ChatGPT (signed out) | `textarea#mobile-composer-prompt` | the signed-in ProseMirror composer isn't served without an account |
| HuggingChat | `textarea[role=combobox]` | **combobox** |
| Qwen, DuckDuckGo AI chat | plain `textarea` | |
| Meta AI | `input` | single line |
| Claude, DeepSeek, Copilot | sign-in page | not reachable signed out |

### Live: engine demos and public editors

| Page | Field | Paste taken over | Notes |
|---|---|---|---|
| ProseMirror example | `div[contenteditable]`, no role | yes | one atom |
| Lexical playground | `div[role=textbox]` | yes | |
| Slate mentions example | `div[role=textbox][aria-multiline]` | yes | four atoms, zero-width characters in the text |
| Quill playground | Quill | yes | |
| Draft.js home | `div[role=textbox]` | yes | the engine reset the selection set from outside |
| CKEditor 5 demo | `div[role=textbox][aria-label="Rich Text Editor. Editing area: main…"]` | yes | eight widget atoms; table cells are nested editables |
| TinyMCE example | `body#tinymce[role=textbox][aria-multiline]` | | inside the editor's own iframe |
| CodeMirror 6 | `div.cm-content[role=textbox][aria-multiline]` | yes | |
| Monaco (and Dillinger) | `textarea` 168×48 | no | the field is a proxy, far smaller than the editor |
| Trix | `trix-editor[role=textbox]` | yes | attachments as atoms |
| Gutenberg demo | `p[role=document][aria-label="Block: Paragraph"][contenteditable]` per block | | inside an iframe titled "Editor canvas" |
| Wikipedia VisualEditor | `div.ve-ce-documentNode[role=textbox]` | no (ignored a synthetic paste) | 127 non-editable atoms (references, templates) in the sandbox |
| Wikipedia source editor | CodeMirror 6 over a hidden `textarea#wpTextbox1` | | |
| StackEdit | `pre[contenteditable]`, its own engine | yes | |

### From bundles

| App | Category | Engine, as the bundles show it | Evidence |
|---|---|---|---|
| Discord | chat | Slate | `data-slate-editor`, `data-slate-node` in the app bundles |
| Microsoft Teams (web, which the new desktop app shares) | chat | CKEditor 5 | chunks `ckeditor5-v39-engine` and `ckeditor5-v47-engine`, `[data-tid='ckeditor'].ck-editor__editable` styles |
| Proton Mail | mail | RoosterJS | a `roosterjs` chunk in the runtime manifest |
| Instagram (Meta) | social | Lexical | `__lexicalEditor` in the focus helpers |
| Gemini | AI chat | Quill in a `rich-textarea` custom element | `rich-textarea .ql-editor` styles |
| ClickUp | tasks | Quill | `.ql-editor`, `cu-ql-dropdown` |
| Bluesky | social | Tiptap / ProseMirror | `ProseMirror-light` and `ProseMirror-dark`, `@tiptap/` |
| Substack | CMS and posts | ProseMirror | `div.ProseMirror.FeedProseMirror` in served HTML |
| Asana | tasks | ProseMirror and Quill | both engines' class names |
| GitHub | code review | textarea with `markdown-toolbar`; CodeMirror 6 for files | `js-comment-field`, `cm-content` |
| YouTube | comments | plain contenteditable inside a custom element | `div#contenteditable-root` created inside a Polymer element |
| WordPress.com | CMS | Gutenberg RichText: one contenteditable per block | `gutenberg-core/…/rich-text` scripts |
| Gmail | mail | its own contenteditable (Closure) | sanitiser allowlists naming `contenteditable`; no engine signature |
| Notion, Linear, Slack, Google Docs, X, LinkedIn, Reddit, ChatGPT, Claude | various | not visible logged out | editor chunks load only after sign-in; sources in engines.md |

### What changed in the set

- **`blocks` engine.** Gutenberg, live and in its bundles, and Notion's page body make every
  paragraph its own contenteditable. No engine covered that. `web/engines/blocks.js` renders
  `p.block-editor-rich-text__editable[role=document]` per paragraph, and the `iframe` embedding
  stands for Gutenberg's editor canvas.
- **`combobox` behaviour.** Grok's ProseMirror and HuggingChat's textarea announce
  `role=combobox`, so Accessibility reports an AXComboBox, not a text area. The new reaction gives
  any engine that role and keeps it there.
- **`xframe` embedding.** Comment widgets and support messengers (Disqus, Intercom, Zendesk) put the
  composer in another origin's iframe, which Chromium runs in its own process and stitches into the
  window's tree. The page now serves the editor from the other loopback name (localhost against
  127.0.0.1, a different site), and the frame reports for itself.
- **No change needed:**
  - Every engine but Monaco takes pastes over, which the engines already do in the set.
  - Teams on CKEditor 5 and Proton Mail on RoosterJS settle two "unverified" rows in engines.md.
  - Gemini's custom elements and YouTube's Polymer composer are what `shadow` stands for.
  - VisualEditor's references and templates are non-editable atoms, like the `mentions` content.
