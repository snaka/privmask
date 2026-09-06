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
