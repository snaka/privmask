# Baseline: what Apple's built-in detectors find in Japanese text

- Measured: 2026-09-06
- Environment: macOS 26.6.2 (25G83), Apple M2 Pro, Swift 6.2.4
- Harness: `swift run AppleAPIProbe` against `Corpus/ja-baseline.json`

The design assumed that `NSDataDetector` and `NLTagger` could carry the
deterministic baseline for Japanese, with an opt-in on-device LLM layer on top.
This measurement was the first task in the plan. It confirmed one half of that
assumption and destroyed the other.

## Result

| Kind | Detector | Expected | Hit | Verdict |
|---|---|---:|---:|---|
| phoneNumber | `NSDataDetector` | 7 | 7 | Excellent |
| address | `NSDataDetector` | 4 | 4 | Excellent |
| personalName | `NLTagger` | 9 | 1 | **Unusable** |
| organizationName | `NLTagger` | 1 | 0 | Unusable |
| email | — | 2 | 0 | Not covered; regex layer |
| postalCode | — | 2 | 0 | Not covered; regex layer |
| myNumber | — | 1 | 0 | Not covered; regex layer |
| credential | — | 3 | 0 | Not covered; regex layer |

The single `personalName` hit was `John Smith`. **No Japanese name was found.**

## Why: NLTagger has no Japanese entity model

This is a platform limitation, not a usage error. Confirmed directly:

```
NLTagger.availableTagSchemes(for: .word, language: .japanese)
  → Language, Script, TokenType

NLTagger.availableTagSchemes(for: .word, language: .english)
  → Language, Script, TokenType, NameType, LexicalClass, NameTypeOrLexicalClass, Lemma
```

`NameType` is simply not offered for Japanese. Setting the language explicitly,
dropping `.joinNames`, and varying the option set all produce nothing. Word
tokenisation *does* work (`田中` / `健一` are split correctly), so the gap is
specifically the named-entity model, not the language support as a whole.

This is pinned by `NLTaggerSupportTests`. If those tests start failing, Apple has
shipped Japanese NER and the personal-name detector should be reconsidered.

## Why this matters more than it looks

`NSDataDetector` handling Japanese phone numbers and addresses well is a real
advantage over regex-based tools. But personal names were the centre of the
differentiation: they cannot be found by pattern matching, which is exactly why
a regex-based competitor cannot do them. Losing `NLTagger` means the *only*
remaining on-device route to Japanese personal names is the Apple Intelligence
on-device model (`FoundationModels`) — which the design placed behind an opt-in,
default-off switch — or the user dictionary.

Note that `fuseji`'s claim that existing PII tools structurally miss Japanese
does **not** hold for `NSDataDetector`: Apple's phone and address models handle
Japanese properly. The claim does hold for entity recognition.

## Defects to work around

1. **Phone matches run across newlines.** `０９０－１２３４－５６７８\n内線: 7788`
   is returned as a single phone number, swallowing an unrelated extension
   number. Detection should be run per line, or matched ranges trimmed at line
   boundaries.
2. **A 12-digit My Number is claimed as a phone number.** The dedicated My
   Number detector must win when ranges collide, so detector precedence has to
   be explicit rather than incidental.
3. **`placeName` fires on product names.** `SwiftNIO` was tagged as a place.
   `placeName` should not be used as a masking signal.

Items 1–3 are pinned by `DataDetectorTests`.

## Consequences for the design

Personal names now depend on the on-device model or the user dictionary. The
model was measured next, in
[on-device-model-baseline.md](on-device-model-baseline.md): it finds Japanese
names reliably, and it was made default-on where available as a result.

`NLTagger` is not discarded entirely — `NameType` *is* available for English, so
it stays as the deterministic path for English names.
