<h1 align="center">🙈<br />privmask</h1>

<p align="center">
  Mask personal information in text before you share it.<br />
  On device, with Japanese handled properly.
</p>

<p align="center">
  <a href="https://github.com/snaka/privmask/releases"><img src="https://img.shields.io/github/v/release/snaka/privmask" alt="Release" /></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT" />
</p>

---

You are about to paste an incident report into Slack, and there are customer
names in it.

```console
$ cat incident.txt
【障害報告】決済 API のレイテンシが悪化。
一次対応: 田中健一 / 二次対応: 佐藤 美咲
連絡先は 090-1234-5678、メールは suzuki@example.co.jp です。
お客様は株式会社サンプル商事、住所は東京都渋谷区渋谷2丁目21番1号。
デプロイ: commit 4f2a1c9e8b3d / v2.14.3 / req 550e8400-e29b-41d4

$ privmask < incident.txt
【障害報告】決済 API のレイテンシが悪化。
一次対応: [NAME_1] / 二次対応: [NAME_2]
連絡先は [PHONE_1]、メールは [EMAIL_1] です。
お客様は[TERM_1]、住所は[ADDRESS_1]。
デプロイ: commit 4f2a1c9e8b3d / v2.14.3 / req 550e8400-e29b-41d4
```

The commit hash, version and request ID are left alone — masking those would
have ruined the report. The same value always gets the same number, so a reader
can still tell who is who.

Nothing is sent anywhere. No account, no API key, no rules fetched from a
server.

## Install

```sh
brew install snaka/tap/privmask
```

## Usage

```sh
pbpaste | privmask | pbcopy     # mask what you just copied
cat app.log | privmask          # or anything on stdin
cat app.log | privmask --json   # findings as JSON, for tooling
```

There is a [Raycast extension](https://github.com/snaka/privacy-mask) that puts
this on a hotkey, with a confirmation step before anything is replaced.

## What it finds

| | Found by |
|---|---|
| Phone numbers, addresses | `NSDataDetector`, including full-width and unhyphenated Japanese forms |
| My Number | Pattern plus check digit, so an order number is not mistaken for one |
| Email, postal codes, API keys and tokens | Patterns |
| Your own terms | A list you keep |
| Japanese personal names | Apple Intelligence, on device |
| English personal names | `NLTagger` |

IP addresses, hostnames and internal URLs are deliberately left alone. Whether
they are sensitive is not something a detector can decide, and masking them
wrongly ruins the text.

## Requirements

macOS 13 or later.

**Japanese personal names additionally need macOS 26 with Apple Intelligence
enabled.** They are found only by the on-device model, which runs by default
wherever it is available. Where it is not, privmask says so on stderr — read
those warnings rather than assuming the text was checked.

## Your own terms

Customer names, company names, project code names — the things no general
detector can know are sensitive. One per line:

```
# ~/.config/privmask/terms.txt
株式会社サンプル商事
Project Bluebird
```

Matching ignores case and character width.

## How it works

```mermaid
flowchart TB
    in["Clipboard · selection · stdin"]

    subgraph mac["Your Mac"]
        direction TB
        pat["Patterns<br/>email · API keys · postal code<br/>My Number, check digit validated"]
        dd["NSDataDetector<br/>phone numbers · addresses<br/>full-width and unhyphenated"]
        terms["Your term list<br/>~/.config/privmask/terms.txt"]
        fm["Apple Intelligence<br/>on-device foundation model<br/>Japanese personal names"]
        merge["Reconcile<br/>precedence · confidence"]
        you["You confirm<br/>what gets masked"]
    end

    out["Masked text<br/>numbered placeholders"]

    in --> pat
    in --> dd
    in --> terms
    in --> fm

    pat -->|milliseconds| merge
    dd -->|milliseconds| merge
    terms -->|milliseconds| merge
    fm -->|seconds| merge

    merge --> you
    you --> out
```

No arrow leaves that box, and that is not a simplification.

It matters because finding a Japanese personal name takes a language model —
patterns cannot, and neither can `NLTagger`, which has no Japanese entity model
at all. Until the on-device model existed, that capability meant sending the
text to somebody's server: handing over the exact thing you were trying not to
share.

The two speeds are why it feels immediate: the deterministic detectors are shown
straight away, and the model's findings are folded in when they arrive.

## Limits

| | macOS 13 – 25 | 26, Apple Intelligence off | 26, on |
|---|:--:|:--:|:--:|
| Everything except the two rows below | ✅ | ✅ | ✅ |
| **Japanese personal names** | ❌ | ❌ | ✅ |
| Spelling variants of your terms | ❌ | ❌ | ✅ |

- Only the first 1,500 characters of Japanese are examined for names. Beyond
  that, names are left in place and a warning is printed.
- The model varies between runs. It finds every name in the test corpus most
  times, not every time.
- Masking is **not reversible**. There is no way to recover the original text
  from the output.
- `--no-model` makes privmask fully deterministic and much faster, at the cost
  of the last two rows above.

## Development

```sh
swift test                      # unit, corpus regression and characterisation tests
swift run AppleAPIProbe         # measure the deterministic layer against the corpus
swift run FoundationModelProbe  # measure the full pipeline, model included (slow)
Examples/use 1                  # put a sample text on the clipboard
```

[`Corpus/ja-baseline.json`](Corpus/ja-baseline.json) carries both what must be
found and what must never be masked; over-masking ruins the text being shared,
so the negative examples count as much as the positive ones.

[`docs/findings/`](docs/findings/) records what was measured about Apple's
detectors and the on-device model, and how it changed the design. Two of the
defects documented there are worked around in this code — both found by reading
output, not by reasoning about the APIs.

```
Sources/PrivMask/       library: detection and masking
Sources/PrivMaskCLI/    the privmask CLI
Sources/*Probe/         measurement harnesses
Corpus/                 ground truth for the regression test
Examples/               sample texts for trying it by hand
```

## License

MIT
