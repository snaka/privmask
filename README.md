# privmask

On-device masking of privacy-sensitive information in text, for Japanese and
English. A Swift package, a CLI, and (separately) a Raycast extension.

**Status:** early development. Detection, masking and the CLI work; the Raycast
extension is next.

## Why

Before pasting a log, an incident write-up, or a customer record into Slack or a
GitHub issue, you want the personal information out of it. Existing tools are
regex-based and miss the things that matter in Japanese — names, addresses,
My Numbers.

Everything runs on device. Nothing is sent anywhere.

## Design

The design record (in Japanese) lives in the `my-task` notes repository:
`tasks/2026-09-06-privmask-design.md`.

Findings that changed the design are in [`docs/findings/`](docs/findings/).

## Use

```sh
cat app.log | privmask
cat app.log | privmask --json
```

Detected values are replaced with numbered placeholders — `[NAME_1]`,
`[EMAIL_2]` — and the same value always gets the same number, so a reader can
still follow who is who. The substitution is not reversible and no mapping is
stored: that table would be a second copy of exactly what the masking removed.

Register your own terms (customer names, project code names) one per line in
`~/.config/privmask/terms.txt`.

## Layout

```
Sources/PrivMask/           # library: detection and masking
Sources/PrivMaskCLI/        # the `privmask` CLI
Sources/AppleAPIProbe/      # deterministic-layer measurement harness
Sources/FoundationModelProbe/  # on-device model measurement harness
Corpus/                     # ground-truth corpus for measuring detectors
Tests/                      # includes characterisation tests for Apple's frameworks
```

## Development

```sh
swift test                    # unit, corpus regression and characterisation tests
swift run AppleAPIProbe       # measure the deterministic layer against the corpus
swift run FoundationModelProbe  # measure the full pipeline, model included (slow)
```

The corpus regression test is the one that matters: detection accuracy is the
product. `Corpus/ja-baseline.json` carries both what must be found and what must
never be masked — over-masking corrupts the text being shared, so negative
examples count as much as positive ones.

## License

MIT
