# Injecting known errors

How to turn a correct text into an `injected` case reproducibly: which errors, how many, where, and what never changes. The rates come from [typing-errors.md](typing-errors.md); where it has no measurement, the number is an **estimate** to calibrate on the owner's real cases from the debug log. The case's `expected` is the clean text exactly as written, and `tags.errors` lists the types injected.

## Error mix

Shares of injected errors, by count. Mixed-language cases use the French mix on French sentences and the English mix on English ones.

| Class | Type (`tags.errors`) | English | French | Basis |
|---|---|---|---|---|
| Keystroke | `substitution` (neighbour key) | 18% | 10% | Dhakal: most errors made; Pollock & Zamora: fewer survive |
| | `omission` | 17% | 10% | Most of what survives (Pollock & Zamora; Baba & Suzuki) |
| | `insertion` | 12% | 7% | Grudin experts; Dhakal |
| | `transposition` | 8% | 5% | Grudin 7%, Pollock & Zamora 12.5% |
| | `spacing` (run-on, split) | 5% | 3% | estimate |
| Accent | `accent` | – | 20% | 32% of French non-word fixes (Wisniewski et al.) |
| Real word | `agreement` (ending *s*, *e*, *-nt*) | 8% | 14% | Top French real-word fixes; Mitton's grammatical real-word errors |
| | `homophone` (confusion sets) | 12% | 11% | Mitton 40% real-word; French 50.5% |
| | `er_e` (*-é/-er/-ez*) | – | 5% | About 2% of French real-word fixes, raised because the owner makes them (estimate) |
| Slip | `doubled_word` | 4% | 4% | estimate |
| | `skipped_word` | 4% | 4% | estimate |
| | `half_edit` | 4% | 4% | estimate |
| Other | `case` | 5% | 1% | estimate |
| | `autocorrect` | 3% | 2% | estimate; replace with real debug-log instances when there are enough |

Keystroke errors are weighted between errors made (Dhakal: substitution 53%) and errors left uncorrected (Pollock & Zamora: omission 34%, substitution 19%), since a draft holds some of each. French moves weight from keystrokes to accents and agreement because half its real fixes are real-word errors.

## How many

- Draw the error count k from a Poisson with λ = characters ÷ 70 (1.4% of characters: between Dhakal's 1.17% left uncorrected and about 3.1% made), then clamp k to [1, ⌊characters ÷ 25⌋]. An `xs` case gets one or two errors; a 1,000-character case about fourteen. Estimate.
- Register: multiply λ by 1.3 for `casual` and by 0.7 for `formal`. Estimate.
- At most one error per word, and at least two words between two errors, except `doubled_word` and `half_edit`, which are word-level by nature.

## Procedure

1. **Seed.** `seed = int(sha256(f"{case.id}|{set_version}|{injector_version}").hexdigest()[:16], 16)`, then one `random.Random(seed)` for the whole case. Every draw below comes from it, in this order, so the same text, id and versions always give the same output.
2. **Protect.** Mark the protected spans (next section) before anything else. A token overlapping a protected span is never a target.
3. **Tokenise** into words with `[\p{L}\p{M}][\p{L}\p{M}'’-]*` and keep their offsets. Tag parts of speech with a pinned spaCy model (`en_core_web_sm`, `fr_core_news_sm`, versions recorded) for the `agreement` and `skipped_word` targets.
4. **Draw** k, then k types from the mix with replacement. For each type, list its eligible targets (table below); if there are none, redraw the type, up to ten times, then drop it.
5. **Pick** a target uniformly among the eligible ones, then the operation's parameters (position in the word, which neighbour).
6. **Apply** the edits from the last offset to the first, so earlier offsets stay valid, and record each one: `{offset, before, after, type}`.
7. **Validate.** Protected spans, line breaks and edge whitespace are byte-identical (the same test as `checks.protected_kept`). Check each keystroke edit with `NSSpellChecker` in the case's language: if it formed a real word, keep it and add `real_word` to the tags (Peterson: up to 16% of single typos do). If the injected text equals the clean text, redraw.
8. **Write** the case with `origin: injected`, the edit log in a sidecar file next to `cases.jsonl` (not part of the contract), and the injector version in the set's version notes.

## Operations

| Type | Eligible target | Operation |
|---|---|---|
| `substitution` | Word of 3+ letters | Replace one letter with a layout neighbour ([typing-errors.md](typing-errors.md#mac-keyboards)), same-row neighbours weighted 2:1. The first letter only with p = 0.18 (Kukich). Layout from `tags.layout`: `azerty` or `qwerty`. |
| `omission` | Word of 3+ letters | Delete one letter, word-medial; one time in three, one of a doubled pair (*tomorow*, *aplication*). |
| `insertion` | Word of 3+ letters | Half the time insert a neighbour of the letter before or after (misstroke); otherwise double a letter (*untill*). |
| `transposition` | Word of 4+ letters | Swap two adjacent letters, not both vowels when another pair exists, never the first pair with p > 0.18. |
| `spacing` | Two adjacent words of 2+ letters, or one of 6+ | Remove the space between them (*ofthe*), or split the word at a random inner position. |
| `accent` (fr) | Word with an accent or *œ* | Drop it (*é è ê → e*, *à → a*, *ç → c*, *ù → u*, *ô → o*, *î → i*) 65%; swap (*é ↔ è*, *a ↔ à*, *ou ↔ où* as words) 25%; *œ → oe* 10%. Never on spellings the 1990 reform allows either way, never on capitals. |
| `agreement` | Noun, adjective, participle or verb with a number or gender ending (spaCy) | Add or remove a final *s*, *e* or *-nt* (fr), or *s* (en): *les fichier*, *elle est parti*, *he go*. |
| `homophone` | A word in the language's confusion sets (below) | Replace it with another member of its set, keeping its case. |
| `er_e` (fr) | Word ending in *-é, -er, -ez, -ais, -ait* that is a verb | Swap to another ending of the set (*j'ai envoyer*, *pour envoyé*). |
| `doubled_word` | Any word, function words weighted 70% | Repeat it with one space (*the the*, *de de*). |
| `skipped_word` | Determiner, preposition, auxiliary or conjunction | Delete it and one adjoining space. Never a negation (*not*, *n't*, *no*, *never*, *ne*, *n'*, *pas*, *jamais*, *rien*, *plus* after *ne*), number or pronoun. |
| `half_edit` | A word from the alternatives table, or an `agreement` target | Leftover: insert its alternative just before it (*I can could send*, *je peux pourrais*). Or stale ending: apply `agreement` as if the subject had changed number or gender. |
| `case` | Capitalised word of 3+ letters, or a proper noun | Shift held over two letters (*THe*) 70%; lowercase a proper noun 30%, only in `neutral` and `formal` register. Never lowercase a sentence start. |
| `autocorrect` | A `substitution`/`omission` result that is not a word | Replace it with `NSSpellChecker`'s first guess that differs from the clean word (record the macOS version), emulating a wrong autocorrection. |

**Confusion sets.** English: *their/there/they're*, *its/it's*, *your/you're*, *then/than*, *to/too*, *lose/loose*, *affect/effect*, *were/where/we're*, *form/from*, *whose/who's*, *of/off*. French: *a/à*, *ou/où*, *et/est*, *sa/ça*, *ses/ces*, *on/ont*, *son/sont*, *ce/se*, *leur/leurs*, *peu/peut*, *quel/quelle/qu'elle*, *mais/mes*. *have → of* (*would of*) only after a modal.

**Alternatives for `half_edit`.** English: *can/could*, *will/would*, *the/this*, *send/share*, *need/want*, *should/could*. French: *peux/pourrais*, *vais/voudrais*, *le/ce*, *envoyer/partager*, *faut/faudrait*, *est/sera*.

## Never touched

Matched before tokenising, and never a target, a neighbour of a `spacing` edit, or part of a `doubled_word`:

- **Mentions and tags**: `@name`, `<@U123>`, `#channel`, `#tag`.
- **Links and addresses**: URLs (with a scheme or `www.`), email addresses, file paths (`~/…`, `/…`, `C:\…`, anything with a `/` and an extension).
- **Code**: backtick spans and fences, and code-shaped tokens: `snake_case`, `camelCase`, `dotted.names`, `--flags`, `key=value`.
- **Emoji and emoticons**: Unicode `Extended_Pictographic` with its ZWJ sequences, skin tones and variation selectors; `:)`, `:D`, `^^`, `xD`, `<3`.
- **Numbers**: digits, dates, times, amounts, versions, phone numbers.
- **Names and acronyms**: tokens in ALL CAPS of two or more letters, proper names (the case's `protect` list, defaulting to capitalised words not at a sentence start).
- **Deliberate register**: slang and abbreviations from a per-language list (English: *lol, lmao, idk, tbh, imo, gonna, wanna, u, ur, pls, thx, dont, im*; French: *mdr, ptdr, jsp, tkt, stp, svp, bcp, pk, pcq, wsh, osef, chui, slt, cc, bjr, ouf*), elongations (*sooo*, *ouiii*), repeated punctuation (*!!!*, *??*), deliberate lowercase, a missing final full stop in chat, and anything else the clean text spells non-standard on purpose.
- **Accepted variants**: 1990-reform spellings either way, French punctuation spacing either way, English words in French text.

## Checks before a case is accepted

- The owner reviews each injected case in the review app like any other (`decision: agree`, `edit`, `drop`), with the edit log shown, and drops any whose injected errors look unlike their own typing (reason `unrealistic`).
- After the first 40 reviewed cases, compare the mix with the types found in the owner's real debug-log cases and adjust the estimated rows. Changing the mix or the procedure bumps `injector_version` and therefore the set's version.
