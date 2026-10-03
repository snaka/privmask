# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["torch==2.7.0", "transformers>=4.44,<4.47", "sentencepiece", "coremltools>=8,<9", "numpy<2.3"]
# ///
"""Prune, export to Core ML INT8, check, and score what ships (#43).

    uv run --managed-python Scripts/ner/export.py .build/ner/model Corpus/ja-names.json .build/ner/export
"""
import glob, json, subprocess, sys, unicodedata
from pathlib import Path
import numpy as np, torch
import coremltools as ct
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from transformers import AutoModelForTokenClassification, AutoTokenizer, PreTrainedTokenizerFast
sys.path.insert(0, str(Path(__file__).resolve().parent)); import nerlib  # noqa: E402

src, corpus_path, out = sys.argv[1], sys.argv[2], Path(sys.argv[3]); out.mkdir(parents=True, exist_ok=True)
tok = AutoTokenizer.from_pretrained(src)
model = AutoModelForTokenClassification.from_pretrained(src).eval()
failures = []

def keep_piece(piece):
    return all(ch.isascii() or 0x3000 <= ord(ch) <= 0x30FF or 0x3400 <= ord(ch) <= 0x4DBF or 0x4E00 <= ord(ch) <= 0x9FFF
               or 0xF900 <= ord(ch) <= 0xFAFF or 0xFF00 <= ord(ch) <= 0xFFEF or unicodedata.category(ch)[0] in "PSZ"
               for ch in piece.replace("▁", ""))

spec = json.loads(tok.backend_tokenizer.to_str())
vocab = spec["model"]["vocab"]
keep = [i for i, (p, _) in enumerate(vocab) if i in set(tok.all_special_ids) or keep_piece(p)]
remap = {o: n for n, o in enumerate(keep)}
spec["model"]["vocab"] = [vocab[i] for i in keep]; spec["model"]["unk_id"] = remap[spec["model"]["unk_id"]]
for t in spec.get("added_tokens", []): t["id"] = remap[t["id"]]
pp = spec.get("post_processor") or {}
if pp.get("type") == "RobertaProcessing":
    pp["sep"] = [pp["sep"][0], remap[pp["sep"][1]]]; pp["cls"] = [pp["cls"][0], remap[pp["cls"][1]]]
(out / "tokenizer.json").write_text(json.dumps(spec, ensure_ascii=False))
small = PreTrainedTokenizerFast(tokenizer_file=str(out / "tokenizer.json"), bos_token="<s>", eos_token="</s>",
                                unk_token="<unk>", pad_token="<pad>", mask_token="<mask>", cls_token="<s>", sep_token="</s>")
emb = model.get_input_embeddings()
new = torch.nn.Embedding(len(keep), emb.weight.shape[1]); new.weight.data = emb.weight.data[keep].clone()
model.set_input_embeddings(new); model.config.vocab_size = len(keep)
print(f"vocab {len(vocab)} -> {len(keep)}, params {sum(p.numel() for p in model.parameters())}")

corpora = {"dev": None, "test": None}
corpus = json.load(open(corpus_path)); corpora["dev"], corpora["test"] = nerlib.split(corpus)
for p in sorted(glob.glob(str(Path(corpus_path).parent / "local" / "*.json"))):
    corpora["local-" + Path(p).stem] = json.load(open(p))
lines = [l for c in corpora.values() for s in c["samples"] for l in s["text"].split("\n") if l.strip()]
differ = sum(tok.tokenize(l) != small.tokenize(l) for l in lines)
if differ: failures.append(f"tokenization differs on {differ} of {len(lines)} lines")

class Wrap(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, ids, mask): return self.m(input_ids=ids, attention_mask=mask).logits
wrap = Wrap(model).eval()
ex = small("担当は佐古宗直です。", return_tensors="pt")
traced = torch.jit.trace(wrap, (ex["input_ids"], ex["attention_mask"]))
seq = ct.RangeDim(lower_bound=1, upper_bound=nerlib.WINDOW + 2, default=64)
ml = ct.convert(traced, inputs=[ct.TensorType(name="ids", shape=(1, seq), dtype=np.int32), ct.TensorType(name="mask", shape=(1, seq), dtype=np.int32)],
                outputs=[ct.TensorType(name="logits")], minimum_deployment_target=ct.target.macOS13, compute_precision=ct.precision.FLOAT16,
                # CPU only here: compiling for the GPU has crashed MPSGraph on this
                # model. Which compute units ship is part B's call.
                compute_units=ct.ComputeUnit.CPU_ONLY)
q = linear_quantize_weights(ml, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric")))
q.save(str(out / "ner.mlpackage"))
q = ct.models.MLModel(str(out / "ner.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)

def mb(p): return int(subprocess.check_output(["du", "-sk", str(p)]).split()[0]) / 1024
size = mb(out / "ner.mlpackage") + mb(out / "tokenizer.json")
print(f"size {size:.1f} MB")
if size >= 100: failures.append(f"size {size:.1f} MB is not under 100 MB")

def predict_ml(ids):
    a = np.array([ids], dtype=np.int32)
    return q.predict({"ids": a, "mask": np.ones_like(a)})["logits"][0].argmax(-1).tolist()
agree = total = 0
for l in lines[:400]:
    ids = small(l, truncation=True, max_length=nerlib.WINDOW + 2)["input_ids"]
    ref = wrap(torch.tensor([ids]), torch.ones(1, len(ids), dtype=torch.long)).argmax(-1)[0].tolist()
    agree += sum(x == y for x, y in zip(predict_ml(ids), ref)); total += len(ids)
print(f"{100 * agree / total:.2f}% of tokens labelled as PyTorch does")
if agree / total < 0.995: failures.append(f"only {100 * agree / total:.2f}% of tokens agree with PyTorch")

for name, c in corpora.items():
    json.dump(nerlib.detections(predict_ml, small, c, "ner"), open(out / f"detections-{name}.json", "w"), ensure_ascii=False)
if failures:
    sys.exit("export checks failed:\n  " + "\n  ".join(failures))
print("export checks passed")