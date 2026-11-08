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

## Workflow

Every change reaches `main` through a pull request, squash-merged once CI passes. `main` takes no direct pushes or force-pushes, and every commit on it is signed.

- Branch from an up-to-date `main` as `<type>/<short-slug>`, using the commit types below: `fix/duplicate-security-link`. One change per branch.
- Commit messages and pull request titles follow [Conventional Commits](https://www.conventionalcommits.org): `<type>(<scope>): <summary>`, imperative and lowercase after the colon, no full stop, under 72 characters.
  - Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`, `revert`. A breaking change adds `!` after the type.
  - Scopes, optional: `app`, `capsule`, `correction`, `editor`, `onboarding`, `settings`, `providers`, `eval`, `bakeoff`, `e2e`, `release`.
- The pull request title becomes the commit on `main` and its description becomes the commit body, so write both for `git log`. The description is plain prose: what changed and why in a short paragraph or two, then a `Verified:` line naming what you ran (`just check`, an e2e scenario, a run in the app). Close a GitHub issue with `Fixes #N`.
- A change people using the app would notice adds a line under the unreleased heading in `CHANGELOG.md`, in the same pull request.
- Open the pull request with `gh pr create`. Merge it only when the person you're working for says to, with `gh pr merge --squash` once CI is green.
- Public content (code, commits, branches, pull requests) never mentions private planning tools, their issue IDs or links, or anyone's personal details.
- Releases are tagged `vX.Y.Z` on `main` (SemVer, `0.x` for now). The tag runs the release workflow.

## Conventions

- Match the surrounding code: its density, naming and comment style. Comments say why, not what.
- The product is called Oops. `CHANGELOG.md` is written by hand for people using the app.
- Debug-only code goes through `DebugFlags` or `#if DEBUG`, so release builds carry none of it.

A change is done when `just check` passes and, if it changes what the app does, it has been seen working in the app (an e2e scenario or a run).
