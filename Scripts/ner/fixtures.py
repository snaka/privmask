# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["transformers>=4.44,<4.47"]
# ///
"""Golden tokenizer output for the Swift port (#46).

For every line of the public name corpus, and a few lines written to exercise
normalisation, the ids and offsets nerlib.line_spans works from, with offsets
in UTF-16 as NSString counts them.

    uv run --managed-python Scripts/ner/fixtures.py .build/ner/export/tokenizer.json Corpus/ja-names.json Tests/PrivMaskTests/Fixtures/ner-tokens.json

Never run it on Corpus/local/: the fixture is committed.
"""
import hashlib, json, sys
from pathlib import Path

from transformers import PreTrainedTokenizerFast

sys.path.insert(0, str(Path(__file__).parent))
import nerlib

# Characters the normaliser changes in length or kind, and offsets that are not
# one UTF-16 unit per character.
EXTRA = [
    "ｶﾞｲﾄﾞ担当の ｻﾄｳ ﾀﾛｳ",
    "ＡＢＣ　１２３　ｱｲｳ",
    "㈱サンプル ① ②",
    "Ａｌｉｃｅ Smith",
    "naïve café",
    "\tタブ\t区切り ",
    "👩‍💻 田中さん",
    "𠮷田さんと髙橋さん",
    "line\r",
    "  ",
    "x" * 300 + " 佐藤",
]

tok_path, corpus_path, out_path = sys.argv[1:4]
assert "local" not in Path(corpus_path).parts, "the fixture is committed; never build it from Corpus/local"
tok = PreTrainedTokenizerFast(tokenizer_file=tok_path, bos_token="<s>", eos_token="</s>",
                              unk_token="<unk>", pad_token="<pad>", mask_token="<mask>", cls_token="<s>", sep_token="</s>")
lines = [l for s in json.load(open(corpus_path))["samples"] for l in s["text"].split("\n") if l.strip()]
rows = []
for line in lines + EXTRA:
    ids, offs = nerlib.line_tokens(tok, line)
    rows.append({"line": line, "ids": ids,
                 "offsets": [[nerlib.utf16(line, a), nerlib.utf16(line, b)] for a, b in offs]})
digest = hashlib.sha256(Path(tok_path).read_bytes()).hexdigest()
json.dump({"tokenizer_sha256": digest, "cls": tok.cls_token_id, "sep": tok.sep_token_id, "lines": rows},
          open(out_path, "w"), ensure_ascii=False, separators=(",", ":"))
print(f"wrote {len(rows)} lines to {out_path}")
