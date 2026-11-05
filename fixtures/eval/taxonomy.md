# Eval set taxonomy

How the 200 cases are spread, so the set covers what people actually type instead of 200 near-identical
examples. Each case is one tuple of the dimensions below, turned into a natural draft. Tuples come from a seeded
generator that meets every quota and covers every pair of language, length, register and error profile at least
once. The error-type mix comes from `fixtures/eval/research/typing-errors.md`.

Status: owner-reviewed synthetic bootstrap, frozen 2 November 2026. Fingerprints: `dataset.json`.
The 200 offline approvals are integrated; this is not yet a corpus of observed app corrections.

## Dimensions and quotas

**Language** (owner decision, 28 October): 140 English, 60 French, of which 20 mix French and English in one
draft. French drafts follow the patterns of real French chat; mixed drafts switch inside sentences.

**Length** (characters): xs under 80: 40 · s 80–300: 70 · m 300–1,200: 55 · l 1,200–4,000: 30 ·
xl 4,000–16,000: 5. The xl cases test the 40-second deadline as much as the model.

### Register

| Register | Cases | Typical length |
|---|---|---|
| Casual chat (team chat, DMs) | 50 | xs, s |
| Polite work chat and short emails | 35 | s, m |
| Prompts to AI assistants and coding agents | 35 | m, l |
| Code review and issue comments | 25 | s, m |
| Status updates and longer emails | 25 | m, l |
| Notes and docs (Markdown) | 20 | m, l, xl |
| Social posts and replies | 10 | xs, s |

### Error profile

| Profile | Cases | What it tests |
|---|---|---|
| Clean: nothing to fix | 30 | Overcorrection, the most costly failure |
| Leave alone: slang, shorthand, stretched letters, coinages, no real error | 15 | Respect for register |
| Light: 1–2 errors | 80 | The common case |
| Moderate: 3–5 errors | 60 | Recall without rewriting |
| Heavy: many errors or barely legible | 15 | Where minimal edits are hard |
| Instruction-like: the draft asks a question or gives an order | 15 | Corrected, never answered or obeyed (spread over the profiles above, counted apart) |

**Error types**, per error (rates from the research): keyboard typos (neighbouring keys on AZERTY and QWERTY,
transpositions, omissions, insertions, doubled letters), cognitive slips (a word typed twice, a word skipped, a
phrase repeated after a restart), real-word errors (form/from, a/à, ou/où, partir/partie), grammar (agreement,
French past participles, future versus conditional, each + plural), accents (French: é, à, ô, ê, î, also in
abbreviations), punctuation and spacing, capitalisation, apostrophes in contractions.

**Protected content**, at least 10 cases each, often several in one draft: mentions (`@handle` and
"Firstname LASTNAME"), URLs and paths, inline code and code blocks, Markdown lists and headings, emoji, numbers
and times (14h45, 2-3), deliberate slang and shorthand, edge whitespace and exact line breaks (including CRLF).

## Origin

- About 40% **injected**: correct drafts with known errors added by the rules in
  `fixtures/eval/research/injection.md`. The expected answer is the original draft.
- About 60% **synthetic**: drafted whole by Opus 5.5 and GPT-6.1 Sol, half each, from tuples and the private style
  profile. Each family proposes the expected answer for the other's drafts; agreement pre-fills it, disagreement
  flags the case for the owner first.
- Later: **real** cases from the debug log (private) and **derived** ones modelled on them.

## Style decisions

Decided by the owner on 28 October. Expected answers follow them, even where the current prompt doesn't yet.

1. **Lowercase starts stay lowercase** in casual registers (chat, social, quick replies), and so does a lowercase
   English "i" there. A capital first letter is usually a phone's auto-capitalisation, not the writer's habit.
   Polite and formal registers get normal capitals.
2. **French punctuation gets its space** before ? ! : ; when it's missing, in French sentences only, never in
   English ones or in code. A plain space is expected; a no-break space (U+00A0) or narrow no-break space
   (U+202F) is accepted as an alternative.
3. **"a priori" and "à priori" are both correct** (the 1990 spelling reform accepts the accent; the dictionary
   form has none), so neither is changed.
4. **No final punctuation is added** where the writer left none.
5. Missing accents on French capitals may be left alone or restored where meaning is clear. Restoration
   is optional, not a necessary fix; existing accents are preserved. Context-sensitive distinctions
   still need judgment.

## Split

150 `dev` and 50 `held`, drawn by stratified sampling so each split keeps the language, length and profile mix.
Held-back cases live outside the repository (`fixtures/eval/README.md`).
