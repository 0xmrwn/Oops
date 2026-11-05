# Native toolkits

How each desktop toolkit builds a text box, and the bake-off's version of it. AppKit, SwiftUI and
the custom view live in `native/` (one app). Catalyst, Qt and Swing are separate apps, in
`catalyst/` and `toolkits/`. All of them poll the runner's server like the web page does.

## AppKit: NSTextView on TextKit 1 and TextKit 2

- Since Ventura, text views default to TextKit 2, which lays out only the viewport. Touching
  `layoutManager` flips a view to TextKit 1 for good. Both read text and selection from the same
  NSTextStorage. No accessibility difference is documented, so the bake-off covers both
  (`NSTextView(usingTextLayoutManager:)`).
- Used by Notes, TextEdit, Mail's plain composer, and most native composers.
- **Here.** Mentions and emoji are NSTextAttachment images (chips), read as U+FFFC.

## AppKit: NSTextField

- Edits go through the window's shared field editor (an NSTextView). Accessibility still reports
  the field: AXTextField, single line.
- Used by search boxes, forms and one-line chat inputs.
- **Here.** The field holds plain text. A re-render sets `stringValue` again, which ends and
  restarts the field editor's session.

## SwiftUI

- `TextEditor` is an NSTextView underneath. `TextField(axis: .vertical)` is a growing composer, the
  pattern SwiftUI chat apps use. `TextEditor` on an AttributedString is new in macOS 26.
- **Here.** The editor reports the app's own state (the binding). A re-render gives the view a new
  identity, so SwiftUI builds a new text view: the native counterpart of a remounted React
  component.

## Mac Catalyst

- UIKit's UITextView and UITextField, bridged to macOS Accessibility by UIKit. Messages and WhatsApp
  are Catalyst apps. One developer reports that setting `AXSelectedText` returns success there
  without replacing anything, so a paste is the reliable write.
- **Here.** Built with `swiftc -target arm64-apple-ios18.0-macabi`, with the scene life cycle.
  Mentions and emoji are attachments, and a modal is a form sheet.

## Custom-drawn text (GPUI, terminals, games)

- Zed (GPUI on Metal), Alacritty, kitty and Ghostty draw their own text. They take input through
  NSTextInputClient, and Accessibility sees little or nothing.
- **Here.** `OpaqueTextView` draws text, implements NSTextInputClient, copy and paste, and reports
  only an AXGroup. With a selection, Oops should go through copy and paste. With none, it should
  refuse.

## Qt

- Qt's own Cocoa bridge maps editable text to AXTextField or AXTextArea, with value and settable
  selection. `AXVisibleCharacterRange` always returns the full range, and bounds-for-range is the
  union of the first and last character rectangles. Telegram Desktop, OBS, VirtualBox and Anki use
  Qt.
- **Here.** PySide6 6.11.2 (pinned wheels, fetched by `setup.py`) with QTextEdit, wrapped in a small
  .app so the process has a bundle like real Qt apps. IME is started with a `QInputMethodEvent`
  preedit.

## Swing

- The JDK's macOS bridge (CAccessibility). Getters run on the event thread through `invokeAndWait`,
  so Accessibility calls block while that thread is busy. JetBrains IDEs' commit and comment fields
  are Swing.
- **Here.** Temurin JDK 21.0.8 (pinned, fetched by `setup.py`) running a single-file JTextArea app
  inside a small .app. There is no IME case: Swing can't start a composition without a person.

## Skipped

- **Flutter (macOS desktop and web).** The SDK costs several GB, and Flutter's text field is a
  hidden NSTextField under the semantics tree, which is off by default. The canvas edge cases cover
  "drawn text, no accessibility unless asked".
- **GTK and wxWidgets.** No common Mac drafting app uses them.
- **Electron with native views, React Native macOS.** React Native macOS renders native
  NSTextViews, which the AppKit cases cover.
