# Typing errors in real drafts

What errors people leave in text typed on a Mac keyboard, and how often, so the `injected` cases carry a realistic mix. Every figure names its source; numbers marked **estimate** are ours, chosen where no study measures the thing. Researched 28 October 2026. The injection procedure built on this is in [injection.md](injection.md).

## Keystroke errors

Four single-character operations cover most typos: substitution, omission (deletion), insertion and transposition. Damerau (1964) found 80% of misspellings rejected by a term list were a single such error, and Kukich (1992) found 78% in deaf-relay chat transcripts, with 27% of errors involving an adjacent key and 18% hitting the first letter of the word (both via Ingels 1997, §2.1).

| Study | Text | Insertion | Omission | Substitution | Transposition | Other |
|---|---|---|---|---|---|---|
| Dhakal et al. 2018, 783 typists from 168,000, all errors made | Transcription, 98% QWERTY | 0.67% of chars (21%) | 0.80% (26%) | 1.65% (53%) | not separated | – |
| Grudin 1983, six expert typists (61–90 wpm), errors left | Transcription, typewriter | 42% (range 17–75) | 14% | 23% | 7% | 14% |
| Pollock & Zamora 1983, 50,000 non-word misspellings that survived into databases | Scholarly abstracts | 27% | 34% | 19% | 12.5% | 7.5% multiple |

- **Made versus left.** Dhakal's typists made errors at about 3.1% of characters and left 1.17% uncorrected (SD 1.43%), after 2.29 corrections per sentence. Baba & Suzuki (2012) compared corrected and uncorrected errors in keystroke logs: substitutions are easy to catch while omissions escape; errors at word edges get corrected more often, so surviving errors sit word-medially; and an omission inside a repeated letter (*tomorow*) survives more than elsewhere. An unsent draft sits between the two: some errors are not yet noticed.
- **Which key.** Substitutions mostly hit a neighbour. In Grudin's expert data, 31% of substitutions were the adjacent key in the same row, 16% the key above or below on the same finger, and 78% stayed within one hand; mirror-image (homologous) errors were 4% for experts. Lessenberry's 60,000 novice errors (via Grudin) give 43% same-row neighbours, 15% same-column, 10% homologous.
- **Insertions** by experts were mostly misstrokes, one finger striking two keys at once (Grudin), so the extra letter is a neighbour of an intended one. Letter doubling of the wrong letter (*weel* for *well*) was rare.
- **Speed.** Faster typists make fewer substitution errors (Dhakal et al. 2018), and 40–70% of fast typists' keystrokes overlap the previous one (rollover), which is where transpositions come from.
- **Real code edits.** The most frequent fixes in the GitHub Typo Corpus's English edits are inserting *s* or *e*, deleting *s* or *e*, inserting *r*, *t*, *i*, *n*, and spaces (Hagiwara & Mita 2020, figure 5): plural and agreement endings head the list, not keyboard slips.
- **Space errors** (two words run together, one word split) are a named category (Ingels 1997, §2.2) but none of the studies above reports their share. Estimate: 5–8% of keystroke errors.
- **Case errors** (*THe*, a lowercase proper noun) have no published rate either. macOS can capitalise the first word of sentences and proper nouns as you type (Apple, *Mac User Guide*), so a missing initial capital is often a choice of register, not a slip.

## Mac keyboards

The layouts below are dumped from macOS itself (`UCKeyTranslate`, 28 October 2026), by physical key on an ISO keyboard. Apple's French layout is not the PC AZERTY: digits need Shift, `!` and `§` sit on the number row, and the bottom row ends `, ; : =`.

```text
French (com.apple.keylayout.French)     ABC / US (com.apple.keylayout.ABC)
@ & é " ' ( § è ! ç à ) -               § 1 2 3 4 5 6 7 8 9 0 - =
 a z e r t y u i o p ^ $                 q w e r t y u i o p [ ]
  q s d f g h j k l m ù `                 a s d f g h j k l ; ' \
 < w x c v b n , ; : =                   ` z x c v b n m , . /
Shift: # 1 2 3 4 5 6 7 8 9 0 ° _ / bottom row > W X C V B N ? . / +
```

`^` and `` ` `` are dead keys on the French layout. With rows numbered by position in this grid, a key's neighbours are the keys either side in its row, plus: for the top letter row, number-row keys c+1 and c+2; for the home row, top-row keys c and c+1; for the bottom row, home-row keys c−1 and c. Weight same-row neighbours twice the others, following Grudin's 31% against 16%.

What the layouts imply (derived from the layout, not measured):

- **AZERTY.** *é è ç à* are one unshifted key each, so a missing accent is haste, not friction. The full stop is Shift + `;`, so a dropped Shift gives `;` where `.` was meant, and `?` is Shift + `,`. *m* sits on the home row beside *l* and *ù*; *a/q* and *z/w* sit where QWERTY has *q/a* and *w/z*.
- **French typed on QWERTY.** Accents need press-and-hold or an Option dead key (Option-e then e for *é*; Apple, *Enter characters with accent marks*), so accents go missing far more often. The owner types on both.
- **Autocorrect.** With *Correct spelling automatically* on, macOS replaces misspelled words as you type (Apple, *Mac User Guide*). It turns a non-word typo into a real word, sometimes the wrong one, and a French word typed under an English input source can be "corrected" into English. No study measures how often; collect real instances from the debug log.

## Cognitive slips

These come from planning the sentence, not the fingers, and the owner reports making them often. Studies name them; none gives a per-sentence rate for adults typing messages, so every rate in [injection.md](injection.md) for this class is an estimate to calibrate on the owner's real cases.

- **Homophone and near-word swaps.** Competent adult writers substitute homophones, more often when the context primes the less frequent one (White et al. 2008, building on Hotopf's slips of the pen). Mitton (1987) found homophones and near-homophones (*where/were*, *have/of*) in close to 60% of pupils' errors, a figure Ingels (1997) suspects the test design inflated.
- **Agreement broken under load.** Highly educated French adults writing dictated sentences made almost no subject–verb agreement errors alone, and many when doing a second task at once (Fayol, Largy & Lemaire 1994); the typical error makes the verb agree with the nearest noun (*le chien des voisins aboient*). Rewriting part of a sentence mid-draft is that kind of load.
- **A word typed twice, a word skipped, a half-finished edit** (a leftover word from the earlier wording, an ending that matched the old subject). No measurement found. Of these, a skipped *not/pas* changes meaning and must never be injected.

## Real-word errors

A real-word error is a misspelling that is itself a word (*form/from*, *there/their*), so a dictionary check can't see it.

- **English.** Mitton (1987) found 40% of errors in 924 pupils' essays were real words, 30% leaving out grammatical ones like agreement (via Ingels 1997). Peterson (1986) estimated that up to 16% of single typing errors in running text produce another valid word, mostly in short frequent words (via Ingels 1997). "Wrong word" is the most frequent error in US first-year college papers, and spelling including homonyms the fifth (Lunsford & Lunsford 2008, ranks as reproduced by secondary sources).
- **French.** Of 146,593 spelling corrections mined from French Wikipedia's history, 74,100 (50.5%) fixed real-word errors (Wisniewski, Max & Yvon 2010). Their most frequent fixes are below; 47% of real-word fixes change the end of the word, which the authors read as agreement within one paradigm.

| Real-word fix (French) | Share | Non-word fix (French) | Share |
|---|---|---|---|
| add final *s* | 16.2% | *e* → *é* | 6.7% |
| add final *e* | 9.9% | *E* → *É* | 6.7% |
| remove final *s* | 8.8% | *oe* → *œ* | 4.6% |
| *A* → *À* | 5.6% | add *n* | 4.3% |
| remove final *e* | 4.9% | add *s* | 2.8% |
| *i* → *î* | 2.7% | add *r* | 2.7% |
| remove final *t* | 1.5% | *é* → *è* | 2.7% |
| *e* → *a* | 1.4% | remove *s* | 2.5% |
| *é* → *er* / *er* → *é* | 1.0% / 0.9% | add *e* | 2.2% |
| *u* → *ù* | 0.9% | *é* → *e* | 2.1% |

Accents account for 32.4% of the non-word fixes; the authors attribute many to capital-letter accent rules and input devices rather than ignorance. Doubled consonants (*n*, *l*, *m*, *t*) come next.

## French specifics

- **Accents.** Missing (*e* for *é*), wrong (*é/è*, *a/â*), on capitals (*Ecole/École*), and *œ* written *oe* (table above). Whether Oops should add accents to capitals is a policy choice: the fix is right but many writers leave capitals bare on purpose.
- **Agreement and endings.** Plural *s*, feminine *e* and verb *-nt* are the top real-word fixes; *-é/-er* swaps are about 2% (table above). Past participles fall in the same class. Grammatical spelling is the main source of French spelling errors in Manesse & Cogis's (2007) dictation study.
- **Homophones.** *a/à* and *ou/où* appear in the table (*A → À*, *u → ù*). The other standard sets: *et/est*, *sa/ça*, *ses/ces/c'est/s'est*, *on/ont*, *son/sont*, *ce/se*, *leur/leurs*, *quel/quelle/qu'elle*, *peu/peut*, *-é/-er/-ez/-ait/-ais*. No source here ranks them.
- **1990 spelling reform.** At least 3% of the Wikipedia fixes rewrote a reformed spelling (*évènement*, *i* without circumflex) into the older one (Wisniewski et al. 2010). Both are correct: never inject either, and judge either as acceptable.
- **Punctuation spacing.** The Office québécois de la langue française puts a non-breaking space before `:` and inside `« »`, and none (or a thin one) before `;`, `!` and `?` (OQLF *Vitrine linguistique*); typographic practice in France differs on the last three. In chat, these spaces are commonly left out. Don't inject spacing errors, and treat spacing changes as neither needed nor harmful.
- **Anglicisms and mixing.** Oops keeps language mixing, so English words in French text are deliberate, not errors.

## English specifics

The common real-word sets: *their/there/they're*, *its/it's*, *your/you're*, *then/than*, *to/too*, *lose/loose*, *affect/effect*, *were/where/we're*, *of/have* (*would of*), *form/from*, *who's/whose*. *its/it's* appears among the GitHub Typo Corpus grammatical examples (Hagiwara & Mita 2020). Casual register drops apostrophes (*dont*, *im*) and capitals on purpose; treat these as slang to keep, not errors to inject.

## Sources

- Baba, Y. & Suzuki, H. (2012). [How are spelling errors generated and corrected? A study of corrected and uncorrected spelling errors using keystroke logs](https://aclanthology.org/P12-2073/). ACL.
- Dhakal, V., Feit, A. M., Kristensson, P. O. & Oulasvirta, A. (2018). [Observations on typing from 136 million keystrokes](https://www.pokristensson.com/pubs/DhakalEtAlCHI2018.pdf). CHI.
- Fayol, M., Largy, P. & Lemaire, P. (1994). Cognitive overload and orthographic errors: when cognitive overload enhances subject–verb agreement errors. *Quarterly Journal of Experimental Psychology* 47A(2), 437–464 (abstract only).
- Grudin, J. (1983). [Error patterns in novice and skilled transcription typing](https://gwern.net/doc/design/typography/1983-grudin.pdf). In Cooper (ed.), *Cognitive Aspects of Skilled Typewriting*.
- Hagiwara, M. & Mita, M. (2020). [GitHub Typo Corpus](https://aclanthology.org/2020.lrec-1.835). LREC.
- Ingels, P. (1997). [A robust text processing technique applied to lexical error recovery](https://arxiv.org/abs/cmp-lg/9702003), ch. 2: secondary source for Damerau 1964, Kukich 1992, Pollock & Zamora 1983, Mitton 1987 and Peterson 1986.
- Lunsford, A. A. & Lunsford, K. J. (2008). Mistakes are a fact of life. *College Composition and Communication* 59(4) (ranks via [secondary reproduction](https://teachingrhetoric.blogspot.com/2009/04/lunsford-and-lunsfords-mistakes-are.html)).
- Manesse, D. & Cogis, D. (2007). *Orthographe : à qui la faute ?* ESF.
- White, K. K., Abrams, L., Zoller, S. M. & Gibson, S. M. (2008). Why did I right that? Factors that influence the production of homophone substitution errors. *Quarterly Journal of Experimental Psychology* 61(7) (abstract only).
- Wisniewski, G., Max, A. & Yvon, F. (2010). [Recueil d'un corpus d'erreurs orthographiques à partir des révisions de Wikipédia](https://aclanthology.org/2010.jeptalnrecital-long.13.pdf). TALN.
- Apple. *Mac User Guide*: [Enter characters with accent marks](https://support.apple.com/guide/mac-help/mh27474), [typing suggestions and corrections](https://support.apple.com/guide/mac-help/mchlp2299).
- Office québécois de la langue française. [Espacement avant et après les signes de ponctuation](https://vitrinelinguistique.oqlf.gouv.qc.ca/22039/la-typographie/espacement/espacement-avant-et-apres-les-signes-de-ponctuation-et-les-symboles).
