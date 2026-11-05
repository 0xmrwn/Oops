# Layouts and behaviours

The dimensions every engine and toolkit is crossed with, why each matters to Oops, and how the
fixtures produce them.

## Layouts

- **Composer**: a chat's bottom composer under a message list. This is the most common draft.
  Placement should anchor to the composer.
- **Thread**: a reply composer in a narrow pane next to the channel (Slack, Teams, Linear comments).
  Two text areas share the window.
- **Side panel**: an assistant or comments panel beside a document (Notion AI, Docs comments,
  Copilot panes). The composer is narrow and the main column is scrollable.
- **Modal**: a "New post" dialog. On the web it is `role=dialog` over a dimmed page. Natively it is
  a sheet (AppKit), a form sheet (Catalyst) or a dialog window (Qt, Swing). The editor is in a
  different window from the main one.
- **Nested scroll**: a small editor box inside a scrolled panel inside a scrolled page, scrolled so
  the box sits mid-view. Geometry and highlights have to follow two scroll offsets.
- **Document**: the editor fills the page (Docs, Notion, Notes). Placement should anchor to the
  caret.

## Presentation

- **Zoom**: on the web, page zoom of 150% (CSS `zoom` on the root, which Chromium, WebKit and Gecko
  all implement). Natively, a 30 pt font. Rects must still land on the words.
- **RTL**: `dir=rtl` and Arabic drafts, with Latin mentions inside them (mixed bidi). Natively, a
  right-to-left base writing direction.

## Content

- **Mentions**: the three forms engines use are a non-editable island (ProseMirror, Slate, Quill,
  Trix, plain contenteditable, TinyMCE, RoosterJS entities, AppKit and Catalyst attachments), editable
  text with an attribute (CKEditor, Draft.js entities, CodeMirror and Monaco decorations), and token
  text (Lexical). A fix must never paste over a mention.
- **Emoji images**: `<img alt>` or an attachment. Accessibility may read the alt text or U+FFFC.
  The image has to survive the correction.

## Reactions

- **Paste interception**: the app answers the paste itself, stopping the browser's and the engine's
  handling, and inserts the plain text through the engine about 80 ms later. On the web this is a
  capture-phase `paste` listener; natively, a ⌘V key monitor or an overridden `paste:`. Oops has to
  confirm a replacement that lands late.
- **Re-render**: after each edit, the app rebuilds the editor from its state 60 ms later. On the web
  this is the engine's own full reload or a remount. Natively it is a storage reset, a new SwiftUI
  identity, or `setText`. Elements Oops held on to may be gone.
- **Slash menu**: the draft ends with a "/" that just opened a command menu at the caret. Focus stays
  in the editor, which points at the menu's active option (`aria-activedescendant`); natively the
  menu is a non-activating child panel. The menu takes arrows, Return and Escape, and closes when
  the caret leaves the "/".
- **Combobox role**: the editor announces `role=combobox` with `aria-autocomplete=list`, as Grok's
  ProseMirror and HuggingChat's textarea do. Accessibility then reports an AXComboBox, not a text
  area. The role is put back if the engine rewrites it. This is web only.
- **IME**: a Japanese composition (marked text) is in progress at the caret. Started through
  NSTextInputClient in WebKit app views and native views, and with a `QInputMethodEvent` in Qt.
  Browsers, Electron and Swing can't start one without a person, so IME cases run only in shells
  that can. Oops should refuse and touch nothing.
  - *Inside a cross-origin frame*, the WebKit shell's `setMarkedText` starts no composition. Those
    cases (IME with the `xframe` embedding) are reported as `unrunnable`, apart from fixture errors,
    and stay in the set in case a later WebKit changes this.

## Targets

- **Whole**: caret at the end of a one-line draft.
- **Selection**: part of the draft is selected. A typo outside the selection must stay.
- **Multiline**: five paragraphs (two empty), with the caret at the end of the middle one.

## Embedding (web)

- **Page**: the editor is in the page's own DOM.
- **Iframe**: a same-origin iframe, as TinyMCE and Gutenberg's editor canvas do.
- **Xframe**: a cross-origin iframe, as Disqus, Intercom and Zendesk widgets are. Served from
  `localhost` inside a `127.0.0.1` page, so Chromium runs it out of process and the parent can't
  reach into it. The frame reports its own state.
- **Shadow**: the editor is inside a shadow root, as web components do (Salesforce Lightning,
  Reddit's new web). Draft.js and TinyMCE classic can't mount in one, so they are left out.

## Left out

- **Ghost text** (inline AI suggestions): no source documents the DOM Gmail or Copilot use, and an
  invented one would test the fixture rather than the technology.
- **Placeholders**: Oops already treats a reported placeholder as an empty draft (the Teams fix).
  Edge cases cover empty-looking fields only through the canvas editor.
