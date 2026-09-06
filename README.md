# privmask

On-device masking of privacy-sensitive information in text, for Japanese and
English. A Swift package, a CLI, and (separately) a Raycast extension.

**Status:** early development. Measuring the platform before building on it.

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

## Layout

```
Sources/PrivMask/       # library: detection and masking
Sources/PrivMaskCLI/    # the `privmask` CLI
Sources/AppleAPIProbe/  # measurement harness (development tool, not a product)
Corpus/                 # ground-truth corpus for measuring detectors
Tests/                  # includes characterisation tests for Apple's frameworks
```

## Development

```sh
swift test              # unit and characterisation tests
swift run AppleAPIProbe # measure Apple's detectors against the corpus
```

## License

MIT
