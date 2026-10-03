#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "torch",
#   "transformers",
#   "sentencepiece",
#   "fugashi",
#   "unidic-lite",
# ]
# ///
"""Run an off-the-shelf NER model over a name corpus and write its personal
names as a DetectionsFile, for NameScore. Phase 1 of #27.

    uv run Scripts/ner-baseline.py tsmatz Corpus/ja-names.json .build/name-score/ner-tsmatz.json

A development harness: Python is fine here because nothing in it ships. Each
model is used zero-shot, as published.
"""

from __future__ import annotations

import json
import re
import sys

from transformers import pipeline

# model id, and the entity groups it uses for a personal name.
MODELS = {
    "tsmatz": ("tsmatz/xlm-roberta-ner-japanese", {"PER"}),
    "llmbook": ("llm-book/bert-base-japanese-v3-ner-wikipedia-dataset", {"人名"}),
    "openai": ("openai/privacy-filter", {"private_person"}),
}


def utf16(text: str, index: int) -> int:
    """A code-point index as NSString counts it: the scorer rejects anything else."""
    return len(text[:index].encode("utf-16-le")) // 2


def locate(entity: dict, line: str, cursor: int) -> tuple[int, int] | None:
    """Where the entity sits in the line. A slow tokenizer (the MeCab-based
    Japanese BERT) gives no offsets, only the decoded word with spaces between
    its pieces, so the word is searched for from the previous match, ignoring
    whitespace."""
    if entity.get("start") is not None:
        return entity["start"], entity["end"]
    chars = [c for c in entity["word"].replace("##", "") if not c.isspace()]
    if not chars:
        return None
    match = re.compile(r"\s*".join(map(re.escape, chars))).search(line, cursor)
    return (match.start(), match.end()) if match else None


def names_in(ner, labels: set[str], text: str) -> list[dict]:
    found = []
    # Line by line, so no input runs past the model's window; offsets are
    # carried back to the whole text.
    start = 0
    for line in text.split("\n"):
        if line.strip():
            cursor = 0
            for entity in ner(line):
                if entity["entity_group"] not in labels:
                    continue
                span = locate(entity, line, cursor)
                if span is None:
                    continue
                cursor = span[1]
                a, b = start + span[0], start + span[1]
                # Trim the whitespace some tokenizers include in a span.
                while a < b and text[a].isspace():
                    a += 1
                while b > a and text[b - 1].isspace():
                    b -= 1
                if a < b:
                    found.append({"text": text[a:b], "location": utf16(text, a), "length": utf16(text, b) - utf16(text, a)})
        start += len(line) + 1
    return found


def main() -> None:
    key, corpus_path, out_path = sys.argv[1:4]
    model_id, labels = MODELS[key]
    ner = pipeline("token-classification", model=model_id, aggregation_strategy="simple")
    # A long line is split with overlap where the tokenizer supports it; a slow
    # tokenizer does not, and lines are short enough without it.
    if ner.tokenizer.is_fast:
        ner = pipeline("token-classification", model=model_id, aggregation_strategy="simple", stride=64)
    seen = sorted({e for e in ner.model.config.id2label.values()})
    sys.stderr.write(f"{model_id}: labels {seen}\n")
    if not any(any(label in e for label in labels) for e in seen):
        sys.exit(f"none of {labels} is among the model's labels; fix MODELS")

    corpus = json.load(open(corpus_path))
    samples = {}
    for n, sample in enumerate(corpus["samples"], 1):
        samples[sample["id"]] = {"names": names_in(ner, labels, sample["text"])}
        sys.stderr.write(f"\r{n}/{len(corpus['samples'])}")
    sys.stderr.write("\n")
    json.dump({"system": f"ner-{key}", "samples": samples}, open(out_path, "w"), ensure_ascii=False, indent=1)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
