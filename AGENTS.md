# AGENTS.md

Oops is a macOS menu-bar app that corrects an unsent draft in place, in whichever app has focus. It is a Swift package (Swift 6.4, macOS 26+): `OopsCore` holds the logic and its unit tests cover it; `Oops` is the app (Accessibility, the capsule, Settings); `OopsEval` is the eval command-line tool, with tests of its own. Labs and end-to-end runs live in `fixtures/`.

## Commands

- `just check [base]` is the gate. It checks only what changed since `base` (default: uncommitted changes), cheapest first, and stops at the first failure: the commit hooks, then the Swift build, then the unit tests when `OopsCore`, `OopsEval` or the tests changed. It prints one line per step; the full output is in `.build/check.log`.
- `just test` runs every unit test; `just setup` installs the pinned tools (`mise.toml`) and the commit hook. `just ci` is CI's gate: every hook on every file, the build and all tests.
- `just update-test` proves a Release build updates itself through Sparkle, as a separate windowless copy (`dev.0xmrwn.oops.update-test`) beside the real Oops.
- `just e2e` runs the quick end-to-end set (native cases, WebKit, one case per bake-off failure class); `just e2e --full` adds every web case in Chrome and Zen. These, `just run` and the `fixtures/*/run.*` scripts bring windows to the front and type into them. Ask before running them when someone may be using the Mac.

`just check` and `just test` are local, quick and safe: run them whenever they help, without asking.

## What the hooks enforce

- Formatting (SwiftFormat, ruff, shfmt, rumdl): formatters fix files in place and fail the run; review what they changed and stage it.
- Lint (SwiftLint, ruff, shellcheck) and no new compiler warnings.
- A token budget: no file over 5,000 tokens (bytes / 4), and a file already over it may only shrink. Files stay small enough for an agent to read whole. When a file would cross it, split it the way the hook's message describes.

Fix what a hook reports rather than bypassing it (`--no-verify`) or loosening its config. If a rule is wrong, say so and why.

## Conventions

- Match the surrounding code: its density, naming and comment style. Comments say why, not what.
- The product is called Oops. `CHANGELOG.md` is written by hand for people using the app.
- Debug-only code goes through `DebugFlags` or `#if DEBUG`, so release builds carry none of it.

A change is done when `just check` passes and, if it changes what the app does, it has been seen working in the app (an e2e scenario or a run).
