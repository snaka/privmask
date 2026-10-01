#!/usr/bin/env python3
"""Draw a seeded pool of family and given names from SudachiDict, for writing
the name corpus (#28).

    python3 Scripts/pick-corpus-names.py --seed 28 > .build/name-score/pool.json

The pool is deliberately not drawn only from what JapaneseSurnames holds. That
list is generated from the same dictionary, so a corpus drawn from it alone
would never show a real name being thrown away by the filter (#22).
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import io
import json
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("generate_surnames", HERE / "generate-surnames.py")
generate_surnames = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate_surnames)

SURNAME = ["名詞", "固有名詞", "人名", "姓"]
GIVEN = ["名詞", "固有名詞", "人名", "名"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--per-group", type=int, default=60)
    args = parser.parse_args()
    rng = random.Random(args.seed)

    surnames: dict[str, int] = {}
    given: set[str] = set()
    readings: set[str] = set()
    for row in csv.reader(io.StringIO(generate_surnames.fetch_lexicon())):
        if len(row) < 12:
            continue
        surface, cost, pos, reading = row[0], int(row[3]), row[5:9], row[11]
        if pos == SURNAME and generate_surnames.is_kanji(surface):
            surnames[surface] = min(cost, surnames.get(surface, cost))
            if generate_surnames.is_katakana(reading):
                readings.add(reading)
        elif pos == GIVEN and generate_surnames.is_kanji(surface):
            given.add(surface)

    # Lower cost means more frequent in SudachiDict's model.
    mid = sorted(name for name in surnames if 2 <= len(name) <= 3)
    mid.sort(key=lambda name: surnames[name])
    quartile = len(mid) // 4
    listed_singles = set(generate_surnames.SINGLE_CHARACTER)

    def pick(names) -> list[str]:
        names = sorted(names)
        return rng.sample(names, min(args.per_group, len(names)))

    json.dump({
        "seed": args.seed,
        "commonSurnames": pick(mid[:quartile]),
        "rareSurnames": pick(mid[quartile:]),
        "singleSurnames": pick(n for n in surnames if len(n) == 1 and n not in listed_singles),
        "longSurnames": pick(n for n in surnames if len(n) >= 4),
        "givenNames": pick(given),
        "katakanaSurnames": pick(readings),
    }, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
