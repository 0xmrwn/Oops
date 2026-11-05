# Web editing engines

One note per engine: how it is built, what that means for an Accessibility client, which apps use
it, and how the bake-off's adapter (`web/engines/`) imitates it. Versions are the pinned ones in
`engines/package.json`. Sources were read on 25 October 2026; "likely" marks a secondary source.

## ProseMirror (through Tiptap)

- **Build.** One contenteditable root redrawn from a document model. A MutationObserver reads the
  browser's own edits back into transactions, so outside text changes are adopted. Paste is
  intercepted (`clipboardData`, HTML then plain text).
- **Atoms.** Leaf nodes such as mentions are `contenteditable=false` spans. ProseMirror adds hack
  nodes (`img.ProseMirror-separator`, `br.ProseMirror-trailingBreak`) but no zero-width characters.
  Tiptap adds `role=textbox`.
- **Apps.** Linear, GitLab, Substack, Atlassian (likely), and ChatGPT's and Claude's web composers.
- **Adapter.** Tiptap 3.31 with StarterKit, the Mention extension and an inline image node. Its
  re-render calls `setContent` with the document's own JSON.

## Lexical

- **Build.** One root that Lexical's reconciler owns. `beforeinput` is the main path. Its safety-net
  MutationObserver *reverts* foreign DOM nodes, and accepts outside text only when no input is
  pending. Paste is intercepted.
- **Atoms.** Mentions are token or segmented text nodes: editable text, deleted whole, with no
  `contenteditable=false`. Typeahead menus set `aria-activedescendant` on the root.
- **Apps.** Facebook, Messenger, Instagram and WhatsApp Web (likely), and Ghost.
- **Adapter.** Vanilla Lexical 0.52 with rich text and history. Mentions are token nodes and emoji
  images inline decorator nodes. Its re-render parses the state again, which gives new keys, so
  every element is rebuilt.

## Slate (slate-react)

- **Build.** React renders every node, and `beforeinput` drives edits. Outside DOM edits are not
  registered. Empty leaves and voids hold U+FEFF in `span[data-slate-zero-width]`, so AXValue
  carries it.
- **Atoms.** Inline voids are `contenteditable=false` with a hidden spacer.
- **Apps.** Discord (its own fork), Grafana, and Canva (likely).
- **Adapter.** Slate 0.133 on React 19, with mentions and emoji as inline voids. It selects through
  `Transforms.select`, because Slate redraws the DOM selection from its own. Its re-render remounts
  the editor with a new React key.

## Quill 2

- **Build.** A Delta document. A MutationObserver feeds the browser's edits back. Paste is converted
  through Quill's clipboard matchers.
- **Atoms.** Embed blots are a `contenteditable=false` span between two U+FEFF guard text nodes.
- **Apps.** Slack's composer began as a Quill 1 fork (likely), as did Gemini's prompt box. Signal
  Desktop is unverified.
- **Adapter.** Quill 2.0.3 (its own browser build), with mention and emoji embed blots. Its
  re-render sets the Delta again, which empties and redraws every line.

## Draft.js

- **Build.** React renders blocks from an immutable EditorState. Draft has been in maintenance since
  2022. DOM writes outside React are ignored or overwritten: synthetic `execCommand` text doesn't
  reach X's state.
- **Atoms.** Entities are text with a decorator.
- **Apps.** X's composer (likely), and older Facebook and CMS fields.
- **Adapter.** Draft.js 0.11.7 on React 17 (it calls `findDOMNode`, which React 19 removed).
  Mentions are immutable entities. Emoji are text drawn as an image behind transparent glyphs. Its
  re-render rebuilds the content under new block keys.

## CKEditor 5

- **Build.** A model, a virtual view and a renderer that diffs only dirty nodes. `beforeinput` is
  re-fired into the engine. Paste is intercepted. Fillers: U+2060 ×7 inline, and
  `br[data-cke-filler]`.
- **Atoms.** A mention is a *text attribute* (`span.mention[data-mention]`, editable text). Widgets
  are non-editable islands.
- **Apps.** Microsoft Teams (its web bundles load `ckeditor5-v47-engine`), and many CMS, helpdesk
  and LMS editors.
- **Adapter.** CKEditor 49 classic build (GPL key), with Essentials, Mention, and an inline emoji
  widget made with `toWidget`. It selects through the model, because CKEditor ignores DOM selection
  while it considers itself blurred. Its re-render is `setData(getData())`.

## TinyMCE

- **Build.** Classic mode edits `<body contenteditable>` inside TinyMCE's own iframe. On macOS the
  body also gets `role=textbox` and `aria-multiline`. Paste goes through a paste bin and DOMPurify.
- **Atoms.** Islands are `contenteditable=false`, and emoticons can be `<img>`.
- **Apps.** WordPress's classic editor, and countless CMS and LMS forms.
- **Adapter.** TinyMCE 8.9 self-hosted (GPL key), with its skin bundled. Mentions are non-editable
  spans. Its slash menu goes in the page around the iframe.

## CodeMirror 6

- **Build.** "Let the browser edit, then read the DOM." Only visible lines and a margin are in the
  DOM, so AXValue can be a window onto the document. Paste reads `text/plain` only.
- **Apps.** Obsidian, Replit, and GitHub's file editor.
- **Adapter.** CodeMirror 6.43 with line wrapping. Mentions are mark decorations (text). Emoji
  images replace their character with an atomic widget, as Obsidian's live preview does.

## Monaco

- **Build.** Lines are painted, not editable. Input goes to a hidden `textarea.inputarea`. With no
  screen reader, on macOS that textarea holds only the word before the caret, or the selection if
  under 500 characters. With one, it holds a page of lines. `accessibilitySupport: "auto"` is what
  web apps ship.
- **Apps.** VS Code, Cursor, GitHub Codespaces, and Azure DevOps.
- **Adapter.** The Monaco 0.57 core with clipboard features and no language services or workers,
  left on "auto". Mentions are decorations. It has no images.

## RoosterJS

- **Build.** A content model written into one contenteditable div. Native typing is left to the
  browser. Read-only entities are spans wrapped with `_Entity` classes.
- **Apps.** Proton Mail (a `roosterjs` chunk in its bundles). Outlook on the web is commonly cited
  but unconfirmed.
- **Adapter.** RoosterJS 9.60 (its own browser build). Mentions are read-only entities and emoji
  plain images. Its re-render writes a model rebuilt from the exported HTML.

## Trix

- **Build.** `<trix-editor>` is the contenteditable. Every action becomes an operation on an
  immutable document, which is redrawn (nodes are replaced). Line breaks are `<br>` inside one block.
- **Atoms.** Attachments are one-character, non-editable `figure`s. Basecamp attaches @mentions this
  way.
- **Apps.** Basecamp, HEY, and every Rails Action Text form.
- **IME.** A composition in Trix isn't visible to Accessibility in WebKit, unlike the other WebKit
  editors, iframes included. The probable reason (unverified) is that Trix handles composition in
  its own document model, so no native marked text exists.
- **Adapter.** Trix 2.1.19 (its own browser build). Mentions and emoji images are content
  attachments.

## Block editors (Gutenberg, Notion)

- **Build.** Every block is its own contenteditable. Gutenberg's RichText renders
  `p.block-editor-rich-text__editable` with `role=document`, `aria-multiline` and
  `aria-label="Block: Paragraph"`. React re-renders a block after each edit, and Enter makes a new
  block. Focus, the caret and Accessibility's focused element are one paragraph, not the document.
- **Apps.** WordPress (Gutenberg, from WordPress.com's scripts), Notion's page body, Craft.
- **Adapter.** `web/engines/blocks.js`: one `p[contenteditable]` per paragraph (empty ones too).
  Chips and images go inside blocks, and a re-render rebuilds every block.

## Wikipedia's VisualEditor (not in the set)

- **Build.** `div.ve-ce-documentNode[role=textbox]`, a model-driven contenteditable. References,
  templates and infoboxes are non-editable islands: 127 in the sandbox page alone.
- **Why not vendored.** It is bound to MediaWiki and very large. Its atoms are what `mentions`
  exercises.

## Plain fields: textarea, input, contenteditable

- **Build.** Native form controls expose AXTextArea or AXTextField with value, selection and
  placeholder. A plain contenteditable is the app reading its own DOM, as Gmail's body and many
  in-house composers do.
- **Adapter.** A textarea's mentions are plain text under a highlight mirror (GitHub, early
  Discord). The contenteditable's mentions are non-editable chips. A re-render swaps the field
  element itself, the way a remounted React component does. `password` and `readonly` are the edge
  set's fields that must refuse.

## Canvas editors

- **Build.** Google Docs draws text on a canvas and takes keys through a hidden contenteditable in
  an iframe. Screen reader support is opt-in (⌘⌥Z), so without it no document text is exposed.
  Flutter web keeps semantics off by default.
- **Adapter.** `engines/canvas.js` draws the draft and keeps a hidden contenteditable that holds
  only the current selection, so the browser's copy works. Accessibility sees that field. These are
  edge cases: with nothing selected Oops should refuse and ask for a selection, and with a selection
  it should correct through copy and paste.
