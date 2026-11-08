# Reliability bake-off

Synthetic editors built from the technologies apps use, and a runner that scores Oops on each.
The set targets the technologies, not any one app's current build: every web
engine runs in every browser shell, and native toolkits run in the layouts apps use. Combinations
are chosen pairwise, so every pair of values meets at least once.

This is a one-off spike. Neither `just check` nor `just e2e` runs it.

## Run it

```bash
fixtures/bakeoff/run.py
```

The runner builds and installs the Debug Oops the way `fixtures/e2e` does: stub provider, debug
log, lab triggers, no sounds. No model is called and nothing is sent. It fetches the runtimes it
needs on first use (`setup.py`), starts each shell once and runs its cases. It **brings windows to
the front and types into them**, so run it only when nobody is using the Mac. A full run takes
about 28 minutes for the 254 committed cases.

- `run.py chrome`, `run.py w012`, `run.py lexical qt`: filters by host, case id prefix, family
  (`web`, `native`, `edge`, `sanity`), engine or toolkit.
- `run.py --cases DIR`: runs the case files in `DIR` instead of the committed set, through the same
  code. The score goes next to `DIR` (`DIR/../score-<name>.json`) unless `--out` says otherwise.
- `run.py --no-build`: reuses the installed Debug build.

Scores go to `.build/bakeoff/score.json`. The file holds one entry per case: each stage graded,
notes on what went wrong, and what Oops captured. A summary at the top gives totals, a tally per
stage, and a pass rate per dimension value.
The file is checkpointed after each case; `complete` is false until every selected case finishes, so
a shell startup failure leaves the completed results available.
Locked sessions and system dialogs stop the run before a correction trigger; they are not counted as
editor failures. The session probe reads only lock state and the frontmost app's identifier.
`python3 fixtures/bakeoff/test_run.py` checks this interruption contract without opening any apps.

## RTL regression set

`regressions/` preserves seventeen previously failing combinations from the November
challenge samples, with their original drafts, dimensions and expectations. Only the IDs have a
`rtl-` prefix. It covers Safari shadow-root input, WebKit/Safari marker-bound replacement, Monaco
proxy capture, Chrome marker padding, Zen restore after rerender, editable document paragraphs, final remount copy proof, attachment-offset aiming, Electron RTL replacement beside images, and an intermittent Zen/Quill partial correction, and spaces beside Gecko images.
It is development regression data, separate from `cases/`; it does not change the benchmark score.

When the screen is available and its use is authorized:

```bash
fixtures/bakeoff/run.py --cases fixtures/bakeoff/regressions --out .build/bakeoff/rtl-regressions.json
```

The combined set passes **17/17**.

## What a case expects

Each case says whether Oops should **work** or **refuse**, and why (`expect.why` in `cases/*.json`):

- **Works.** Five stages are graded:
  - *capture*: Oops read exactly the draft or selection, give or take atoms and invisible
    characters.
  - *apply*: the outcome is fixed, the editor's own model holds the corrected text, and its chips
    and images are intact.
  - *revert*: the original text and atoms are back.
  - *highlight*: at least one flash rect was placed, and the flash lies inside the field's frame,
    give or take 6 points. The frame is measured from Oops's highlight panel and the probe's
    `bounds`. No word's pill may cover the field (90 % of its width and height): that's a placeholder
    taken for the word's place, which lights up the whole draft.
  - *placement*: the capsule anchored to the composer or the caret, not the window or the screen.

  Editors that expose no text but support copy and paste on a selection skip revert and highlight,
  by design (docs/compatibility.md).
- **Refuses.** Three stages are graded:
  - *refused*: capture stopped, so no model was asked.
  - *untouched*: text and atoms are unchanged.
  - *message*: the message names the reason.

  This applies to password fields, read-only text, an IME composition in progress, and editors that
  expose no text when nothing is selected.

The editors report their own model (ProseMirror's document, Lexical's state, the SwiftUI binding,
and so on), not what Accessibility reads. So a correction counts only if the app itself took it.

### How a case runs

1. A first correction is answered with garbage by the stub. It fails at the provider, changes
   nothing, and logs exactly what Oops captured.
2. The stub's real answer is that capture with the draft's typos fixed, so it matches whatever the
   editor exposes, as a real model's answer would.
3. A second correction is the real one. Chromium shells get a 2.5 s model delay, so their
   accessibility switch has settled before the flash.

### Fixture errors

A case only counts against Oops if its fixture is right. Before the first correction, the runner
checks four things:

- the editor holds the case's draft;
- the engine's selection landed where the case put it;
- the browser's own selection matches the engine's;
- for an IME case, a composition is in progress.

Any mismatch is reported as `fixture-error` and left out of the score.

`web/selftest.html` mounts every engine with every content type. Serve it with
`fixtures/bakeoff/server.py` and open the URL it prints followed by `selftest.html`. It then selects, inserts and re-renders through each
adapter, to check the adapters themselves without Oops.

## Layout

| Path | What it holds |
|---|---|
| `matrix.py` | Dimensions, impossible pairs and the pairwise generator. `--check` verifies the committed cases. |
| `drafts.py` | Each case's draft (two typos, atoms, an Arabic version) and its expected result. |
| `cases/` | The committed set: `web.json` and `native.json` (pairwise), `edge.json` (refusals and canvas editors) and `sanity.json` (each engine in each shell, plainly). |
| `run.py`, `grade.py`, `hosts.py`, `oops.py`, `server.py` | The runner. |
| `setup.py` | Pinned, checksummed downloads (Electron, JDK, PySide6) into `.build`. `--vendor` rebuilds `vendor/`. |
| `engines/` | `package.json` with the pinned engine versions, and the bundle entries. |
| `vendor/` | The engine builds the page loads. Not in Git: `setup.py --vendor` builds it (needs bun). |
| `web/` | The page: layouts, behaviours, and one adapter per engine. |
| `shells/` | The WebKit app shell and the Electron app. |
| `native/`, `catalyst/`, `toolkits/` | AppKit and SwiftUI, Mac Catalyst, and Qt and Swing apps. |
| `tools/flashes.swift` | Records the frames Oops's flash panel takes, for the highlight stage. |
| `notes/` | Research notes per engine, shell and toolkit, and what the installed and web apps showed. |

## Changing the set

Edit `matrix.py` or `drafts.py`, then run `fixtures/bakeoff/matrix.py` to regenerate `cases/`. A
case you write by hand needs:

- the dimension fields;
- a `draft` (paragraphs of `{text}`, `{mention}` or `{emoji}` segments);
- `text`, `typos`, and `caret` or `selection`;
- `expect` (`result`, `stages`, `message`, `why`).

Put it in a JSON list in any directory and pass `--cases`.
