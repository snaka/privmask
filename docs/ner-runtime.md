# The NER layer at runtime: compute units, the product's score, and speed

- Measured: 2026-10-03
- Environment: macOS 26.6.2 (25G83), Apple M2 Pro, Apple Intelligence enabled
- Harness: `FoundationModelProbe` (`PRIVMASK_NER_MEASURE=1` for the compute-unit
  timing; the ordinary run for the score), on a release build
- Model: the export from #45, `.build/ner/export`, loaded through
  `NERResources.directory()` and `NERDetector.load(from:computeUnits:)`

## Compute units

Time to load the model, and to detect over all 109 samples of
`Corpus/ja-names.json`. "Differing" counts samples whose detected names (text and
location) are not identical to the `cpuOnly` run.

| compute units        | load  | corpus | samples differing from cpuOnly |
|----------------------|-------|--------|--------------------------------|
| `cpuOnly`            | 0.39s | 3.82s  | 0 |
| `cpuAndNeuralEngine` | 0.40s | 3.79s  | 0 |
| `.all`               | -     | -      | process aborts |

- The two settings agree on every sample and take the same time. The Neural
  Engine is not faster for this model on this machine.
- The very first load after the model is built or moved is slower and is not
  the steady state: 0.67s for `cpuOnly` and 2.76s for `cpuAndNeuralEngine`, the
  latter while Core ML compiles for the Neural Engine. Subsequent runs were
  0.4s for both.
- `.all` (which allows the GPU) aborts the process:
  `MPSGraphExecutable.mm: failed assertion 'Error: MLIR pass manager failed'`.
  It cannot be caught, so the probe does not measure it.
- `cpuOnly` is the default, and this measurement found nothing faster or
  different: the Neural Engine took the same time and gave the same names.

## The product's score with NER

`FoundationModelProbe Corpus/ja-names.json`, with `PRIVMASK_NER_DIR` set: the
deterministic pipeline, NER, and the on-device model together, which is what the
CLI produces. Scored with `NameScore` against each half of the corpus,
`.build/ner/dev.json` and `.build/ner/test.json`, which
`python3 Scripts/ner/nerlib.py split Corpus/ja-names.json .build/ner` makes.

| half | recall | precision |
|------|--------|-----------|
| dev  | 92.3% (234 expected)  | 98.7% (5 false positives of 393 detections) |
| test | 97.0% (533 expected)  | 98.1% (18 false positives of 939 detections) |

For the test half, #45 reported 95.5% recall and 97.9% precision for
privmask ∪ NER. The difference is the language model, which varies between runs.
This run predates the change to the Latin check below.

In that run 2 of 109 samples had their only chunk fail in the language model
(`markdown-opus-02`, `hard-method-name`); their names come from the deterministic
layer and NER alone. The whole run took 3m41s, nearly all of it the language
model (mean 1.97s per sample, slowest 13.27s). NER adds 3.8s over the corpus.

## What the Swift NER layer drops of Python's

The Swift layer applies a check Python did not: a span must contain Japanese, or
be Latin text shaped like a name (`LatinNameShape`, the check the language
model's Latin names pass, #32 and #40). `NERParityTests` compares Swift with
Python's detections after that check, so it cannot see what the check drops.

After one-letter tokens (`S. Suguri`, `koyaba_j`, `nagatsuta.m`) and kanji
outside the BMP were let through, the check drops three of Python's detections:
`koyadmin` and `Zoom` on the test half, `kawanomics` on the dev half. Recall did
not change, so on the test half both were false positives.

Scored with `NameScore` on the test half, 533 expected names. Swift NER's
detections are `NERDetector.detect(in:)` over each sample, as `NERParityTests`
runs it; the unions are with #45's `privmask.json` (privmask without NER), by
`nerlib.py union`, so no new language model run is involved:

| detections                | recall | precision |
|---------------------------|--------|-----------|
| Python NER                | 91.9%  | 97.4% (18 false positives of 703) |
| Swift NER                 | 91.9%  | 97.7% (16 false positives of 701) |
| privmask ∪ Python NER     | 95.5%  | 97.9% (19 false positives of 913) |
| privmask ∪ Swift NER      | 95.5%  | 98.1% (17 false positives of 911) |

## Speed on a long log

A 5,000-line ASCII log, with a Japanese name on every 250th line, through the
release binary: `privmask --no-model --no-dictionary`, with
`PRIVMASK_NER_DIR=.build/ner/export`. Same machine as above (Apple M2 Pro, 12
cores).

|                              | with NER | `--no-ner` |
|------------------------------|----------|------------|
| one line at a time           | 21.8s    | 2.8s       |
| lines run concurrently       | 9.8s     | 2.9s       |

NER makes one Core ML call per non-blank line. Run one after another, NER added
about 3.8 ms of wall time per line, tokenizing included (21.8s less 2.8s, over
5,000 lines). The lines are independent, so `NERDetector.detect(in:)` runs
them with `concurrentPerform`; output is byte-identical to the sequential run.
The gain stops at about 2.2 times with 12 cores: wall time halved while CPU
time went from 21s to 44s, so the calls do not scale with cores. Lines are not packed into
one call, because that changes what the model sees and so its labels.

