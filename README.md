# Oops

A macOS menu-bar app that corrects text in the focused editor. Select a passage,
or leave the cursor in a draft, and press **⌃⌘W**. Oops asks your chosen model for
small corrections, checks the result, and applies the edits in place. It never
sends the message.

Apple silicon, macOS 26 or later. Written in Swift, with SwiftUI and AppKit.

## How correction works

Oops reads the field through Accessibility. It uses the selection when there is
one, otherwise the whole draft. Editors expose text in different ways, so capture
can use a field's value, text markers, or a copy of the selected text.

The model returns a JSON object containing the corrected text. Oops compares it
with the draft and checks each edit before applying it. Code, URLs, mentions,
paths, line breaks and boundary whitespace are protected. The default prompt
preserves tone and language mixing; answers that rewrite or reply to the draft
are rejected. The correction instructions can be edited in Settings.

Before replacing text, Oops checks the field, draft, selection and clipboard
ownership. If the draft has changed or a replacement cannot be confirmed, Oops
refuses the edit or reports what it could apply. It does not retry an uncertain
paste blindly.

Press the shortcut again to restore an unchanged corrected draft. A third press
reapplies the cached fix without another model call. This works for five minutes
after a correction, restore or reapply. Typing in the field starts a new
correction instead. Copy-only editors cannot confirm the result, so they have no
restore or highlights.

Terminal apps, password managers and fields identified as sensitive are excluded.
Apps can also be disabled individually. Some editors hide active input-method
composition from Accessibility; finish composing before invoking Oops. See
[editor compatibility](docs/compatibility.md) for tested editors and known limitations.

## Providers

| Connection | Request path |
| --- | --- |
| ChatGPT | Browser sign-in; direct Responses API calls using the signed-in account. |
| Claude Code | The installed, signed-in `claude` CLI, with a fresh process per correction. |
| OpenAI API | Responses API with a project API key. Separate from ChatGPT sign-in. |
| Other APIs and local servers | OpenAI-compatible Chat Completions with strict JSON-schema output. |

Models are discovered from the provider. Remote API endpoints require HTTPS;
HTTP is accepted for loopback addresses. Local inference still needs a running
server and a model that supports the required response format.

Claude Code runs with tools, MCP, customizations and session persistence disabled.
Oops leaves its authentication to the CLI. ChatGPT tokens and saved API keys use
the macOS login Keychain.

## Data and permissions

Accessibility lets Oops read and edit the focused field when invoked. It does not
watch idle typing. A correction sends the captured selection or draft and the
correction instructions to the chosen provider. Requests go directly to that
provider, without an Oops server in between. The provider's own data policies
still apply.

Clipboard-based capture and replacement temporarily use the system clipboard.
Oops saves its contents first and restores them only while it still owns the
clipboard entry, so it does not overwrite something copied during a correction.
The original draft is kept in memory for recovery for five minutes.

Usage statistics stay on the Mac and contain counts, timing, app and model names,
not draft text. The diagnostic log is off by default. Enabling it in Settings
stores drafts, prompts and model responses locally under
`~/Library/Application Support/oops/Debug/`. Those files contain the text you
asked Oops to correct.

## Build

The build uses Xcode 27.0 (27A266a), Swift 6.4, Python 3 and
[mise](https://mise.jdx.dev/). Tool versions are pinned in `mise.toml`.

From the checkout:

```sh
mise exec -- just setup
mise exec -- just run --build-only
```

The development bundle is `dist/oops.app`. `just run` builds, installs and launches
it from `~/Library/Application Support/oops/Development/oops.app`. Grant
Accessibility to that runtime copy. Development builds use ad-hoc signing unless
a local signing identity is configured; rebuilding with a different signing
identity can require granting permissions again.

| Command | Checks |
| --- | --- |
| `just check` | Hooks, build and tests selected from the uncommitted changes. |
| `just test` | All unit tests. |
| `just ci` | Hooks on all files, build, unit tests and release-tool tests. |
| `just e2e` | Local editor tests through the app with a stub provider. |

The e2e tests bring windows forward and type into them. Accessibility tests run
locally; hosted CI does not grant those permissions.

The web cases load editor bundles that aren't in Git: build them once with
`python3 fixtures/bakeoff/setup.py --vendor` (needs [Bun](https://bun.sh)).

Release builds are arm64. Sparkle uses a signed ZIP for updates; the DMG is for
installation. The development app has no update feed.

## Source layout

- `Sources/Oops/`: app lifecycle, editor access, correction sessions, drop overlay,
  Settings and onboarding.
- `Sources/OopsCore/`: provider adapters, correction rules, text transactions and
  placement policies.
- `Sources/OopsEval/`: the `oops-eval` command-line tool.
- `Tests/`: unit tests. `fixtures/`: editor labs, e2e scenarios and evaluation
  fixtures.

See the [evaluation CLI reference](docs/eval.md) to run correction cases through
the provider adapters.

## License

The code is [MIT-licensed](LICENSE). Copyright 2026 0xmrwn.

The ChatGPT marks are OpenAI brand assets, used under
[OpenAI's brand guidelines](https://openai.com/brand/). Other third-party code
and assets keep their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Reports and suggestions

Bug reports and ideas go in issues. Oops does not accept external pull requests.
See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately through
GitHub, as described in [SECURITY.md](SECURITY.md).
