"""Shared pieces of the NER pipeline (#43): the corpus split, held-out names,
and the inference rules part B mirrors in Swift.

    python3 Scripts/ner/nerlib.py split Corpus/ja-names.json .build/ner
    python3 Scripts/ner/nerlib.py union .build/ner/union.json union a.json b.json
    python3 Scripts/ner/nerlib.py check
"""
from __future__ import annotations

import hashlib, json, re, sys, unicodedata

DEV_SHARE = 0.37  # about 40 of 109 samples

def side(sample_id: str) -> str:
    """dev or test, from the id alone, so adding samples never moves one."""
    h = int(hashlib.sha256(sample_id.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return "dev" if h < DEV_SHARE else "test"

def split(corpus: dict) -> tuple[dict, dict]:
    def keep(s): return {**corpus, "samples": [x for x in corpus["samples"] if side(x["id"]) == s]}
    return keep("dev"), keep("test")

def held_out_names(paths: list[str]) -> set[str]:
    """Every name and name part in these corpora: the training data may use none."""
    out: set[str] = set()
    for p in paths:
        for s in json.load(open(p))["samples"]:
            for e in s["expected"]:
                out.add(e["text"])
                out.update(t for t in re.split(r"[\s　・._\-]+", e["text"]) if t)
    return out

def utf16(text: str, i: int) -> int:
    return len(text[:i].encode("utf-16-le")) // 2

def spans_from_labels(offsets, labels) -> list[tuple[int, int]]:
    """B starts a name; I continues it, and starts one when nothing precedes it."""
    spans: list[list[int]] = []
    open_ = False
    for (a, b), lab in zip(offsets, labels):
        if a == b:  # special or empty token
            open_ = False
            continue
        if lab == 1 or (lab == 2 and not open_):
            spans.append([a, b]); open_ = True
        elif lab == 2:
            spans[-1][1] = b
        else:
            open_ = False
    return [tuple(s) for s in spans]

def plausible(text: str, words: frozenset = frozenset(), names: frozenset = frozenset()) -> bool:
    """Whether a merged span may be a name. Applied after merge, to each span.

    In order, on the span NFKC-folded (ｸｴﾘ is クエリ), with lengths in code points:
    no letter at all: drop; one character and a word list given: keep only a
    listed name (林, 関); exactly a word and not a listed name: drop (内線, クエリ;
    森 stays). Then, on the span as written: a single kana: drop; an all-capitals
    ASCII word: drop (MEDIUM, INFO, by the rule #32 set). See #43."""
    folded = unicodedata.normalize("NFKC", text)  # ｸﾗｳﾄﾞ is クラウド
    if not any(ch.isalpha() for ch in folded):
        return False
    if len(folded) == 1 and words and folded not in names:
        return False  # a lone character is a name only when it is a listed one (林, 関)
    if folded in words and folded not in names:
        return False
    if len(text) == 1 and ("\u3040" <= text <= "\u30ff" or "\uff66" <= text <= "\uff9d"):
        return False
    if text.isascii() and text.isalpha() and text.isupper() and len(text) > 1:
        return False
    return True

def merge(spans) -> list[tuple[int, int]]:
    out: list[list[int]] = []
    for a, b in sorted(spans):
        if out and a < out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [tuple(s) for s in out]

# Tokens per call, leaving room for <s> and </s>, and how many of them the next
# window repeats. A window starts WINDOW - OVERLAP tokens after the last.
WINDOW, OVERLAP = 254, 64

def line_spans(predict, tokenizer, line: str) -> list[tuple[int, int]]:
    """Names in one line, windowing a line longer than the model takes."""
    enc = tokenizer(line, add_special_tokens=False, return_offsets_mapping=True)
    ids, offs = enc["input_ids"], enc["offset_mapping"]
    # A lone word-boundary piece (U+2581) is given the offset of the character
    # after it by the HF tokenizer; it is not part of any name, so it is made
    # empty, and spans come only from pieces that carry text. (#43 review)
    pieces = tokenizer.convert_ids_to_tokens(ids) if hasattr(tokenizer, "convert_ids_to_tokens") else [None] * len(ids)
    offs = [(b, b) if piece == "\u2581" else (a, b) for piece, (a, b) in zip(pieces, offs)]
    found, start = [], 0
    while True:
        chunk = ids[start:start + WINDOW]
        labels = predict([tokenizer.cls_token_id] + chunk + [tokenizer.sep_token_id])[1:-1]
        # Strip each piece's leading whitespace from its offsets.
        offsets = [(a + (len(line[a:b]) - len(line[a:b].lstrip())), b) for a, b in offs[start:start + WINDOW]]
        found += spans_from_labels(offsets, labels)
        if start + WINDOW >= len(ids):
            return merge(found)
        start += WINDOW - OVERLAP

def detections(predict, tokenizer, corpus: dict, system: str, words: frozenset = frozenset(), names: frozenset = frozenset()) -> dict:
    samples = {}
    for s in corpus["samples"]:
        text, found, base = s["text"], [], 0
        for line in text.split("\n"):
            for a, b in line_spans(predict, tokenizer, line) if line.strip() else []:
                if not plausible(line[a:b], words, names):
                    continue
                a, b = base + a, base + b
                found.append({"text": text[a:b], "location": utf16(text, a), "length": utf16(text, b) - utf16(text, a)})
            base += len(line) + 1
        samples[s["id"]] = {"names": found}
    return {"system": system, "samples": samples}

def union(system: str, files: list[str]) -> dict:
    out: dict = {}
    for f in files:
        for k, v in json.load(open(f))["samples"].items():
            out.setdefault(k, {"names": []})["names"] += v["names"]
    return {"system": system, "samples": out}

def check() -> None:
    assert spans_from_labels([(0, 2), (2, 4), (4, 5)], [1, 2, 0]) == [(0, 4)]
    assert spans_from_labels([(0, 2), (2, 4)], [2, 2]) == [(0, 4)], "I with no B starts a name"
    assert spans_from_labels([(0, 0), (0, 2)], [1, 1]) == [(0, 2)]
    assert merge([(0, 4), (2, 6), (8, 9)]) == [(0, 6), (8, 9)]
    assert merge([(0, 2), (2, 4)]) == [(0, 2), (2, 4)], "adjacent names stay apart"
    assert utf16("𠮷田さん", 2) == 3, "a non-BMP kanji is two UTF-16 units"
    words = {"内線", "クエリ", "森", "本"}
    names = {"森", "佐古"}
    assert not plausible("内線", words, names) and not plausible("クエリ", words, names), "a dictionary word is not a name"
    assert plausible("森", words, names), "a word that is also a family name is kept"
    assert plausible("佐古宗直", words, names) and plausible("田中", words, names)
    assert not plausible("ｸｴﾘ", words, names), "half-width katakana is folded before the lookup"
    assert not plausible("_", words, names) and not plausible("達", words, names) and plausible("森", words, names)
    assert not plausible("が") and not plausible("ｶ") and not plausible("MEDIUM")
    assert plausible("林") and plausible("Jun Mannou") and plausible("ゆい")
    assert side("abc") == side("abc") and {side(f"s{i}") for i in range(50)} == {"dev", "test"}

    class Tok:  # one character per token, to test windowing without a model
        cls_token_id, sep_token_id = -1, -2
        def __call__(self, line, add_special_tokens, return_offsets_mapping):
            return {"input_ids": list(range(len(line))), "offset_mapping": [(i, i + 1) for i in range(len(line))]}
    line = "あ" * 600 + "田中"  # the name sits past the first window
    predict = lambda ids: [0] + [1 if i == 600 else 2 if i == 601 else 0 for i in ids[1:-1]] + [0]
    assert line_spans(predict, Tok(), line) == [(600, 602)], "a name past the first window is found"
    # Through detections, a listed single-kanji family name survives the filter.
    one = {"samples": [{"id": "x", "text": "森さんと林さん"}]}
    tag = lambda ids: [0] + [1 if i in (0, 4) else 0 for i in ids[1:-1]] + [0]
    got = [n["text"] for n in detections(tag, Tok(), one, "t", frozenset({"森"}), frozenset({"森", "林"}))["samples"]["x"]["names"]]
    assert got == ["森", "林"], f"listed single-kanji names must survive detections: {got}"
    print("nerlib: all checks passed")

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "check":
        check()
    elif cmd == "split":
        corpus = json.load(open(sys.argv[2]))
        dev, test = split(corpus)
        for name, c in (("dev", dev), ("test", test)):
            json.dump(c, open(f"{sys.argv[3]}/{name}.json", "w"), ensure_ascii=False, indent=1)
        print(f"dev {len(dev['samples'])}, test {len(test['samples'])}")
    elif cmd == "union":
        json.dump(union(sys.argv[3], sys.argv[4:]), open(sys.argv[2], "w"), ensure_ascii=False)