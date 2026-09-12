# Baseline: the on-device model as the personal-name detector

- Measured: 2026-09-06
- Environment: macOS 26.6.2 (25G83), Apple M2 Pro, Apple Intelligence enabled
- Harness: `swift run FoundationModelProbe`, plus targeted probes

`NLTagger` cannot do Japanese named-entity recognition
([apple-detector-baseline.md](apple-detector-baseline.md)), which left the
on-device Apple Intelligence model as the only route to Japanese personal names.
This measures whether it can carry that load.

**Summary: it is accurate enough, and slow, size-limited, and refuses a common
shape of our target input unless the text is pre-filtered.**

## Accuracy

| Kind | Expected | Hit |
|---|---:|---:|
| personalName | 9 | **9** |
| phoneNumber | 7 | 7 |
| address | 4 | 4 |
| email | 2 | 2 |
| organizationName | 1 | 1 |

Every Japanese personal name was found, across kanji, hiragana, katakana, and
romaji. This is the capability the product needs and cannot get anywhere else.

False positives, over two runs:

- `7788` (an extension number) read as a phone number — a `mustNotDetect` violation
- `192.168.1.100` read as an address — a `mustNotDetect` violation
- `web-01.internal.example.com` read as an organisation name
- Whole `KEY=value` lines read as personal names, in the credentials sample
- `鈴木一郎 様` classified as an organisation name in one run but not the other

Run-to-run variance is real: the same input produced different classifications
on consecutive runs. Regression tests over this layer must assert a lower bound
("these must be found"), never an exact set.

### The model paraphrases spans

In one run the model returned `090-1234-5678` for input that actually reads
`０９０－１２３４－５６７８` — it normalised full-width digits to half-width. The
returned span does not occur in the input.

`FoundationModelDetector` therefore locates every returned span in the source and
discards anything it cannot find, counting it as "ungrounded". Without that
check, ranges would silently point at the wrong text.

## It refuses mixed-language input

A log line combined with Japanese is rejected outright:

```
GenerationError.unsupportedLanguageOrLocale("Unsupported language.")
```

The failure tracks Apple's own language identifier exactly:

| Input | `NLLanguageRecognizer` | Model |
|---|---|---|
| `2026-09-05 14:32:01 [ERROR] api-server: upstream timeout` + 日本語 | **`id` (Indonesian, 0.38)** | **FAIL** |
| 日本語 + the same log line | `en` (0.30) | OK |
| 【障害報告】… (Japanese first) | `ja` (1.00) | OK |
| log line alone | — | OK |
| Japanese alone | — | OK |

Timestamps, hostnames, and identifiers mixed into Japanese push the language
identifier onto an unsupported language, and the model then refuses the whole
input. This is precisely the "incident report pasted into Slack" case the
product is for, so it is not an edge case.

### Mitigation: send only lines containing Japanese

Filtering the input to lines that contain kana or kanji fixed every failing case:

| Input | Whole text | Japanese lines only |
|---|---|---|
| 142 chars | FAIL | **OK** |
| 284 chars | FAIL | **OK** |
| 568 chars | FAIL | **OK** |

This also shrinks the input, which matters because of the limits below. English
text needs no such help: `NLTagger` does support English `NameType`, so English
names can be handled deterministically and the model does not need to see them.

## Latency and size limits

> **Superseded on 2026-09-12.** The cap measured here was later replaced by
> chunking, and the throughput figures did not reproduce. See
> [*Batching*](#batching-what-a-second-round-of-measurement-added) below.

Measured on entity-dense synthetic Japanese logs (a name, phone, and address on
every line), with varied content so the model cannot short-circuit on repetition:

| Input | Duration | Result |
|---:|---:|---|
| 436 chars | 5.94s | OK |
| 891 chars | 13.29s | OK |
| 1,803 chars | 30.10s | OK |
| 3,622 chars | 22.65s | **`exceededContextWindowSize`** |

Latency grows roughly linearly with input, and the context window runs out
somewhere between 1.8K and 3.6K characters of Japanese. Note the failure at
3,622 characters still burned 22 seconds before reporting.

An earlier run over *repeated* text stayed flat at ~1.4s regardless of length;
that was an artefact of the repetition and should not be trusted.

Sparser text is faster — the corpus samples (37–258 chars) ran in 1.3–5.0s — so
output length, not just input length, drives the cost.

## Consequences for the design

*Superseded in part on 2026-09-12: the cap below became a chunk size, and
nothing is skipped beyond it.*

- The LLM layer must be given only the Japanese-bearing lines, both to avoid the
  language rejection and to stay inside the context window.
- The cap decided in the design ("LLM only, skip beyond it, say so") needs a
  concrete number, and it has to be low. Tens of seconds is not compatible with
  "mask it quickly before pasting".
- `NLTagger` should be kept for English text, where `NameType` does work. The
  split becomes: English names deterministically, Japanese names via the model.
- With the model now the default-on and sole source of personal names, its
  latency is the perceived speed of the whole extension. Showing deterministic
  results immediately and folding in model results as they arrive is worth
  considering.

## What was settled, and the numbers after settling

Three changes came out of the measurements above, and the pipeline was
re-measured over three consecutive runs to account for the model's variance.

1. **Only the Japanese-bearing lines are sent**, each mapped back to its offset
   in the original text. This removes the language rejection and shrinks the
   request.
2. **Only `personalName` is accepted from the model.** `organizationName` was
   tried and abandoned — the model used it as a catch-all, returning `サポート窓口`,
   `緊急連絡先`, `環境変数の例` and whole lines such as `住所: 〒150-0002 …`.
   Organisation names come from the user dictionary instead. Phone numbers,
   addresses, emails, postal codes, My Numbers and credentials are all at full
   recall deterministically, so the model's opinion on them costs without paying:
   it read `8080`, `1,234,567円` and `E-4521-9` as addresses.
3. **Returned spans are sanity-checked**: a span longer than 24 characters or
   containing structural punctuation is not a name. The model had returned
   `マイナンバー: 123456789018` as a personal name.

Narrowing the prompt to names also halved latency — mean 1.5s against 2.4s.

### Result over three runs

| | run 1 | run 2 | run 3 |
|---|---:|---:|---:|
| Recall, all eight kinds | 29/29 | 29/29 | 29/29 |
| Over-masking violations | 2 | 1 | 2 |
| Unexpected detections | 12 | 8 | 12 |

Recall is solved: every expectation in the corpus is met on every run, with
Japanese personal names coming from the model and everything else deterministic.

**The open problem is false positives from the model.** Eight to twelve spurious
findings across seven short samples, of which one or two would corrupt the text
if accepted. They are consistently common nouns and labels — `サポート窓口`,
`緊急連絡先`, `全角表記`, `内線` — or a name embedded in a compound, such as `田中`
inside `田中式アルゴリズム`.

Every one of these is marked low confidence and shown for confirmation, so none
of them is masked without being seen. But the design assumed the confirmation
step would be reviewed, and a screen carrying ten noise items per paste is a
screen people stop reading. That is the same failure the design worried about
when it decided to measure NLTagger before trusting it.

## Reducing the model's false positives: where it plateaued

Four changes were made and measured over three runs each.

**Routing the model's findings through the pipeline's precedence rules** rather
than appending them to the result removed a third of the noise at a stroke. A
span the model calls a personal name, which a deterministic detector has already
claimed as a phone number, an email or an address, is the deterministic finding.
Containment was not enough on its own: the model returns spans that *wrap* a
deterministic finding — `03-1234-5678（日中）` as a personal name — so a
model-only finding is now dropped when it overlaps a more confident finding of a
different kind in either direction.

**Three span-shape rules**, each a general fact rather than a corpus-specific
patch: a name contains at least one letter (`7788` was returned as one); a name
does not contain を, which in modern Japanese is only ever the accusative
particle (`田中式アルゴリズムを採用`); a name does not contain structural
punctuation.

**Prompt narrowing** — telling the model that roles, departments, contact
channels and section headings are not names, that a family name inside a
compound is not a name, and that an empty list is the correct answer when there
are no names.

| | Baseline | + precedence | + span rules | + prompt |
|---|---:|---:|---:|---:|
| Unexpected detections | 12 | 7 | 5–7 | 7 |
| Over-masking violations | 2 | 2 | 0–3 | 2 |

Recall held at 9/9 personal names in five of the six measured runs, and 8/9 in
the other two.

**Prompt work has plateaued.** The last iteration changed nothing except to make
the output more repeatable — the same seven false positives now appear on every
run:

- `サポート窓口`, `ナビダイヤル`, `緊急連絡先`, `全角表記`, `内線` — every one of them
  from the single corpus sample that contains no personal names at all. Asked to
  find names in text that has none, the model offers the nearest available word,
  and saying so explicitly in the instructions did not stop it.
- `田中` and `式`, decomposed out of `田中式アルゴリズム`.

Note that all five of the first group would be rejected by checking the
candidate against a list of Japanese family names — none of them begins with
one. `田中` would not be, since 田中 is a real surname.

### Verifying the model against a family-name list

The plateau was broken by checking the model's output against a list of common
Japanese family names — as a *verification* step, never as a detector. Used as a
detector, such a list only finds names somebody already thought of, which is the
weakness the model exists to cover. Used as a check on the model, it costs
nothing and rejects exactly what the model reaches for when a text has no names
in it.

Two rules, in `FoundationModelDetector.isNameShaped`:

- A Japanese name is written in one script. `サポート窓口` mixes katakana and
  kanji, so it is not one.
- A kanji or katakana candidate must begin with a family name from the list.
  `緊急連絡先`, `全角表記`, `内線`, `式` do not. Latin and hiragana candidates are
  accepted unchecked: there is no reliable signal, and a wrong rejection costs a
  missed name.

The model's own `kind` label is now ignored entirely — only its span is used.
`鈴木一郎` came back labelled as an organisation name in two runs out of three,
and honouring that label lost a real name. What the text looks like is a better
guide than what the model called it.

### Where it ended up, over five runs

| | Baseline | Final |
|---|---:|---:|
| Unexpected detections | 12 | **1** |
| Over-masking violations | 2 | **1** |
| Japanese personal names | 9/9 | 9/9 in three runs, 8/9 in two |

The single remaining false positive is `田中`, decomposed out of
`田中式アルゴリズム`. 田中 is a real family name, so no list can reject it; only
knowing that it sits inside a compound would, and that is a judgement the model
is already failing to make. It is shown as low confidence, and unchecking it is
one keystroke.

The intermittent miss is `鈴木一郎`, which the model returns in most runs but not
all. It appears in the text as `担当: 鈴木一郎 様` — a name the deterministic layer
cannot see at all, so when the model skips it, it is missed.

## The recall gap that is left: a name that comes after others

The one miss the corpus tracks deliberately. `鈴木一郎` is not found in either
sample that contains it, run after run.

It is not about how the name is written. Isolated, every one of these is
detected:

```
株式会社サンプル商事（鈴木一郎 様、090-1234-5678）から連絡あり。
（鈴木一郎 様、090-1234-5678）から連絡あり。
株式会社サンプル商事の鈴木一郎 様から連絡あり。
担当は鈴木一郎 様です。
```

It is about position. Given the same four-line report:

| Where `鈴木一郎` sits | Result |
|---|---|
| Third name, after 田中健一 and 佐藤 美咲 | **missed** |
| First name, before the other two | found, and so are the other two |
| Only name in the text | found |

The line it sits on already carries a company name, a phone number and an email,
so the model has several candidates competing on one line and returns the ones it
returns. Recall degrades for names that appear later, not for names that are
written a particular way.

Two things follow. The obvious one is that this is a real limit on what the model
will do for a dense record — the more people a text mentions, the more likely one
of them survives. The less obvious one is that a corpus sample where nothing is
missed would have hidden it: `name-after-others` exists to keep the number
honest, and `FoundationModelProbe` is expected to report it as a miss.

## Batching: what a second round of measurement added

- Measured: 2026-09-12
- Environment: macOS 26.6.2 (25G83), Apple Intelligence enabled
- Harness: targeted probes against `FoundationModels` directly, plus
  `privmask --json` over markdown-shaped input

The cap above was chosen to keep one model call inside the context window. The
question this round asks is what it would cost to stop truncating and send the
whole input as several calls instead.

### Concurrent sessions do not overlap

Four chunks of ~712 characters each, run as four `LanguageModelSession`s:

| | Wall clock |
|---|---:|
| Sequential | 9.96s |
| Concurrent (`withThrowingTaskGroup`) | 9.35s |
| Speed-up | **1.06x** |

The on-device model serialises. Whatever the framework accepts, the work queues,
so splitting an input into N chunks costs N times the latency however the calls
are issued. **Concurrency is not a way to pay for coverage.**

### Splitting does not cost latency

The same 2,812 characters, as four calls and as one:

| | Duration | Entities |
|---|---:|---:|
| 712 chars × 4, sequential | 9.96s | 40 |
| 2,815 chars × 1 | 12.32s | 39 |

Per-call overhead is low enough that chunking is not the slower option. The
entity counts are one run of a non-deterministic model and are not evidence of a
recall gain; they are consistent with
[the name-after-others effect](#the-recall-gap-that-is-left-a-name-that-comes-after-others),
which predicts that fewer candidates per call should help. Three runs over the
corpus are what would settle it.

### These numbers disagree with the table above, and that is unresolved

The 2026-09-06 table reports 13.29s at 891 characters and
`exceededContextWindowSize` at 3,622. This round measured roughly 280 characters
per second and completed a single 2,815-character call — inside the range the
earlier run reported as failing, and about five times faster.

Two candidate explanations, neither tested: the model changed under a system
update, or the probe's shortened instructions changed the cost. **Treat the
throughput figures here as provisional** and re-measure with
`FoundationModelProbe` over the corpus, which holds the instructions constant.

### A degenerate fragment makes the model run away

Truncation does not only drop text. When the cap leaves behind a fragment too
small to mean anything, the model is handed an input with no names in it and
asked for a list. Sending it the four characters `# 報告`:

| Run | Result |
|---|---|
| 1 | `exceededContextWindowSize` after **58.2s** |
| 2 | ok, 1.1s, 3 entities — none of them names |
| 3 | ok, 0.8s, 2 entities — none of them names |

The instructions say an empty list is the expected answer. It still reaches for
something, and two runs in three it generates until the 4,096-token context is
exhausted. The invented spans are rejected downstream by `isPlausibleName`, so
they cost nothing but time; the runaway costs most of a minute.

`GenerationOptions(maximumResponseTokens:)` bounds that cost without removing
the behaviour:

| Cap | Fragment `# 報告` |
|---|---|
| none | 58.2s failure, or ~1s with invented entities |
| 512 | ~6s `decodingFailure`, or ~1s with invented entities |

A cap is a ceiling on the damage, not a fix. The fix is to not send fragments.

The cap does not cut legitimate output. A dense 589-character chunk containing
ten names returned all ten under no cap, under 512, and under 1,024, in 2.4–3.0s
each.

### Line granularity is the limit that actually bites

`JapaneseText.batch` packs whole lines and stops at the first line that will not
fit. That suits log-shaped input, where a line is short. It does not suit
markdown, where a paragraph is one line.

A real report — 10,037 characters, of which the Japanese was **3 lines totalling
2,138 characters** — puts roughly 713 characters on a line. Two lines fit under
the 1,500 cap and the third is dropped, so a name in the third paragraph is
never looked for.

A single paragraph longer than the cap is worse: no part of it is sent, and what
remains may be the fragment case above.

| Input | What happened |
|---|---|
| 713 chars × 3 lines | third name left unmasked, `modelInputTruncated: true` |
| one 1,746-char line | nothing of it examined; the 4-character heading went instead, and the model exhausted the context in 2 of 3 runs |

In the second case the CLI reported `modelInputTruncated: false`, because the
`catch` around the model call discards the `Outcome` that carries the flag.
Truncation caused the failure and truncation is what the report denies.

### Consequences

- **Chunk, do not truncate.** Coverage costs latency in proportion to the
  Japanese in the input, and there is no way to buy it back with concurrency.
- **Split inside a line.** Line granularity is an assumption about logs that
  markdown breaks.
- **Never send a fragment**, and set `maximumResponseTokens` so that the case
  that slips through is bounded.
- **Isolate failures per chunk.** One runaway must not lose the names the other
  chunks found, and a chunk that failed has to be reported as unexamined rather
  than silently dropped.

## Chunk size: what it trades, and why the default stays

- Measured: 2026-09-13
- Harness: `PRIVMASK_CHUNK_CHARS=<n> swift run FoundationModelProbe`, three runs
  per size

[The batching change](#batching-what-a-second-round-of-measurement-added) left
one number unsettled. `defaultCharacterLimit = 1500` was chosen to keep a single
call inside the context window; once the cap stopped being a ceiling on
coverage, what it trades is per-call overhead against
[the recall gap for a name that comes after others](#the-recall-gap-that-is-left-a-name-that-comes-after-others),
which argues for smaller chunks. [#1](https://github.com/snaka/privmask/issues/1)
proposed exactly that as the mitigation.

It was measured. **It works, and the way it works is unacceptable.**

| Chunk | personalName | Over-masking | Unexpected | Latency |
|---:|---|---:|---:|---:|
| 1500 | 10/12, 10/12, 10/12 | 1 | 2 | ~26s |
| 800 | 10/12, 9/12, 11/12 | 1 | 2 | ~22s |
| 400 | 10/12, 10/12, 10/12 | 1 | 2 | ~25s |
| 200 | 10/12, 10/12, 10/12 | 1, **2**, 1 | 2–3 | ~22s |
| 100 | 11/12, 10/12, 10/12 | 1, **2**, 1 | 2–4 | ~41s |
| 60 | **12/12, 12/12, 12/12** | **3, 4, 4** | 5–7 | ~39s |
| 40 | 12/12, 11/12, 12/12 | **2, 3, 3** | 3–5 | 21–48s |

### The first three rows are the same measurement

No corpus sample is longer than 393 characters, so at 1500, 800 and 400 every
sample is a single chunk and the computation is identical. The spread across
those nine runs — 9/12 to 11/12 — is the model's own variance, and it is the
scale against which any real effect has to be judged.

### At 60 the missing name is found, every run

`鈴木一郎` is the name [#1](https://github.com/snaka/privmask/issues/1) is about.
It sits on a line that also carries a company name, a phone number and an email,
and the competition is *within that line* — 62 characters of it. Chunking above
that does nothing, which is why 200 and 100 do not move it: they never split the
line. At 60 the line splits, and the name is found in all three runs.

### And the model starts masking the things the README promises to leave alone

| Chunk | What it called a personal name |
|---:|---|
| 1500 | `田中`, decomposed out of `田中式アルゴリズム` — the single documented case |
| 60 | `田中`, and also `commit`, `v2.14.3`, `4f2a1c9e8b3d` |

The README's opening example is a deploy line kept intact:

> `デプロイ: commit 4f2a1c9e8b3d / v2.14.3 / req 550e8400-e29b-41d4` — the commit
> hash, version and request ID are left alone, because masking those would have
> ruined the report.

At 60 characters a chunk, that line becomes a chunk of its own with no names in
it, and [what happens then was already measured](#reducing-the-models-false-positives-where-it-plateaued):
asked to find names in text that has none, the model offers the nearest
available word. Small chunks manufacture exactly that situation, over and over.
Three to four over-masking violations against a documented baseline of one is
not variance.

At 100 there is a second cost, the one #1 predicted: `高橋 由美`, found at every
larger size, is missed in two runs of three. A name split from the sentence that
identifies it as a name gets harder to spot, not easier.

### Conclusion

**The default stays at 1500.** Chunk size buys recall by destroying precision,
and the precision it destroys is the property the tool is built around — that
the surrounding document survives. A name left in place is visible in the
confirmation list; a masked commit hash is a report nobody can read.

This does not close #1. It rules out the mitigation #1 proposed, and names the
reason: the competition is inside a line, so nothing that splits *between* lines
can reach it, and splitting *within* a line costs more than it returns. A fix
would have to make the model better at a crowded line, not give it less to read.
