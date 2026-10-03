# The NER layer at runtime: compute units and the product's score

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
- `cpuOnly` stays the default. Nothing here argues for changing it.

## The product's score with NER

`FoundationModelProbe Corpus/ja-names.json`, with `PRIVMASK_NER_DIR` set: the
deterministic pipeline, NER, and the on-device model together, which is what the
CLI produces. Scored with `NameScore` against each half of the corpus
(`.build/ner/dev.json`, `.build/ner/test.json`).

| half | recall | precision |
|------|--------|-----------|
| dev  | 92.3% (234 expected)  | 98.7% (5 false positives of 393 detections) |
| test | 97.0% (533 expected)  | 98.1% (18 false positives of 939 detections) |

For the test half, #45 reported 95.5% recall and 97.9% precision for
privmask ∪ NER. The Swift runtime with the model is at least as good, so the port
loses nothing; the difference is the language model, which varies between runs.

In that run 2 of 109 samples had their only chunk fail in the language model
(`markdown-opus-02`, `hard-method-name`); their names come from the deterministic
layer and NER alone. The whole run took 3m41s, nearly all of it the language
model (mean 1.97s per sample, slowest 13.27s). NER adds 3.8s over the corpus.
