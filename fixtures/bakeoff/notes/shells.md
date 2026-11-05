# Shells

What hosts a web editor, how its Accessibility comes alive, and how the bake-off runs it
(`hosts.py`). Every shell loads the same page from the runner's local server.

## WebKit: Safari

- Safari and every WKWebView use the same WebCore accessibility. The tree is built when it is first
  asked for, and served off the main thread (the isolated tree, on for macOS since 2026). Documents
  with no plain value read through text markers. `AXValue` writes on a contenteditable behave like
  typing (`clearText` then `insertText`).
- **Run.** The runner opens a new Safari window through AppleScript (Safari has no throwaway
  profile). At the end it closes only windows titled "oops composer lab …", or quits Safari if it
  wasn't running.

## WebKit: app web views

- Tauri apps (wry), Mail's composer, and any app that hosts a WKWebView. The engine is Safari's,
  without Safari's chrome around it.
- **Run.** `shells/WebShell.swift`: one WKWebView in an AppKit window. It is the only web shell that
  can start an IME composition without a person: the page asks over a message handler, and the view
  calls `setMarkedText` through NSTextInputClient.

## Chromium: Chrome

- Accessibility is lazy. An `accessibilityRole` query gives a basic tree with no inline text boxes.
  The full tree needs `AXEnhancedUserInterface`, debounced about 2 seconds. Oops sets the switch at
  capture, so the stub waits 2.5 s on Chromium shells before answering, as a real model call would.
- **Run.** `open -na "Google Chrome" --args --user-data-dir=<temp> --app=<page>`, in a throwaway
  profile that is deleted afterwards.

## Gecko: Zen

- Accessibility starts on the first request, or on `AXEnhancedUserInterface`. Gecko then tracks only
  focus that moves after that. Oops wakes each Gecko browser when its first window comes to the
  front. Content-process trees are cached in the parent, one per tab.
- **Run.** A throwaway profile with a `user.js` that skips the welcome flow, the default-browser
  prompt and updates. The runner waits 3 s after the window opens. A reload per case moves focus,
  which Gecko then follows.

## Electron

- Electron answers both `AXManualAccessibility` and `AXEnhancedUserInterface`, and switches to full
  mode after a 2-second quiet window. Slack, Discord, Notion, Linear, Obsidian, Signal, VS Code,
  Figma and Claude are Electron on macOS.
- **Run.** Electron 44.7.0 (pinned and checksummed, fetched by `setup.py` into `.build`), with a
  throwaway `--user-data-dir`. `shells/electron/main.js` is one BrowserWindow on the page. Its
  windows take the page's title.

## Not covered

- **Chromium-based browsers other than Chrome** (Arc, Edge, Brave, Comet) share Chrome's
  accessibility code, so Chrome stands for them.
- **CEF apps** (Spotify, Steam) embed Chromium the same way. Their text fields are rarely drafts.
- **WebView2 on macOS** (reported for the new Teams, disputed) is Chromium. Electron and Chrome
  bracket it.
