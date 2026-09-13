# What the platform offers for classifying a Japanese word

- Measured: 2026-09-13
- Environment: macOS 26.6.2 (25G83), Apple M2 Pro, Apple Intelligence enabled
- Harness: one-off probes against `NaturalLanguage`, in the shape of the ones in
  `Sources/AppleAPIProbe`

The on-device model returns a span and calls it a name. Something has to check
that claim, because the model reaches for the nearest available word when a text
contains no names at all — it returned `どこ` and `のでしょうか` from an ordinary
question, and both were masked (#15).

For kanji and katakana that check is `JapaneseSurnames`, a hand-written list. The
question this answers is whether the platform offers anything better, so that the
hiragana case could be decided by a rule rather than another list.

**Summary: it does not. There is no Japanese part-of-speech model on the system,
and the two signals that do exist are not accurate enough to gate masking on.**

## `NLTagger` has no Japanese model for any of the schemes that would help

```swift
NLTagger.availableTagSchemes(for: .word, language: .japanese)
```

| Scheme | Available for Japanese |
|---|---|
| `.lexicalClass` | **no** |
| `.nameType` | **no** |
| `.lemma` | **no** |

This is not a gap that shows up as an error. `NLTagger` runs, returns tags, and
every tag is `OtherWord`:

```
どこ          どこ/OtherWord
のでしょうか   の/OtherWord でしょう/OtherWord か/OtherWord
さくら        さくら/OtherWord
```

The absence of `.nameType` was already known
([apple-detector-baseline.md](apple-detector-baseline.md)); the absence of
`.lexicalClass` is what closes the part-of-speech route specifically.

## Tokenization works, but token count classifies badly

`NLTokenizer` segments Japanese correctly — the one part of the pipeline that
does have a Japanese model behind it:

```
どこ / を / 見れ / ば / 良い / の / でしょう / か / ？
```

That makes "a name is one token" look like a rule. It is not. Over 20 hiragana
given names and 18 function words:

| | One token | More than one |
|---|---:|---:|
| Given names (should be one) | 15 | **5** |
| Function words (should be many) | **10** | 8 |

It fails in both directions at once. `ことね`, `ゆりあ`, `ひまり`, `えま` and
`ゆきの` segment into two tokens; `どこ`, `これ`, `ください` and `ありがとう`
stay as one. Rejecting multi-token spans would cost a quarter of the names and
still let more than half the filler through.

## There is no Japanese word embedding

```swift
NLEmbedding.wordEmbedding(for: .japanese)  // nil
```

## Contextual embeddings exist and are not accurate enough

`NLContextualEmbedding(language: .japanese)` is available, 512 dimensions, with
assets present on the machine. Trained as a nearest-centroid classifier — 10
hiragana given names against 10 function words, mean-pooled token vectors, cosine
similarity — it scores **14/20 on held-out spans**.

The errors are the ones that matter:

| Span | Classified | |
|---|---|---|
| `のでしょうか` | name | **the exact false positive this was meant to reject** |
| `りん` | other | a real name, rejected |
| `あん` | other | a real name, rejected |
| `すみません` | name | |
| `おねがい` | name | |
| `わかりました` | name | |
| `どこ` | other | correct |

The margins are the more telling result: `ことね` scored 0.869 against the name
centroid and 0.856 against the other, `えま` 0.864 against 0.859. At these
lengths the space does not separate the two classes at all, so no threshold
recovers the accuracy. Over-masking is the failure this project refuses, and a
70% gate is not a gate.

## Off-platform: morphological analysers would work, at a price

MeCab, Sudachi, Lindera and Vibrato all do real part-of-speech analysis, and
IPAdic carries a `名詞,固有名詞,人名` subcategory that would classify `どこ` as a
pronoun, `のでしょうか` as auxiliary plus particle, and could replace
`JapaneseSurnames` outright.

What stops it is distribution, not capability. The privmask binary is 0.8 MB.
`mecab-ipadic` is tens of megabytes of dictionary and its newest release is
2007-08-01; MeCab itself is 0.996, from 2013. A native dependency plus a
dictionary two orders of magnitude larger than the program is a change to what
this tool is, not a fix for two false positives.

Worth revisiting only as its own decision: replacing the hand-written surname
list with a real analyser, measured against the corpus, accepting the size.

## What was built instead

`JapaneseNonNameWords` — a hand-written denial list, in the same idiom as
`JapaneseSurnames` and for the same stated reason: a word missing from it costs
one false positive on a low-confidence finding the user still sees, whereas an
allow list of hiragana given names would cost a real name every time it was
short.
