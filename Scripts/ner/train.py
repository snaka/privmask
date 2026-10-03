# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["torch==2.7.0", "transformers>=4.44,<4.47", "sentencepiece", "accelerate", "datasets", "numpy<2.3"]
# ///
"""Fine-tune the name NER (#43).

    uv run --managed-python Scripts/ner/train.py .build/ner/train.jsonl .build/ner/model --epochs 1
"""
import argparse, json, time
from datasets import Dataset
from transformers import (AutoModelForTokenClassification, AutoTokenizer, DataCollatorForTokenClassification,
                          Trainer, TrainingArguments, set_seed)

BASE, TOKENIZER = "microsoft/Multilingual-MiniLM-L12-H384", "FacebookAI/xlm-roberta-base"
LABELS = ["O", "B-PER", "I-PER"]

ap = argparse.ArgumentParser(); ap.add_argument("train"); ap.add_argument("out"); ap.add_argument("--epochs", type=int, default=1)
a = ap.parse_args()
set_seed(43)
tok = AutoTokenizer.from_pretrained(TOKENIZER)

def encode(batch):
    enc = tok(batch["text"], truncation=True, max_length=256, return_offsets_mapping=True)
    enc["labels"] = [[-100 if x == y else 0 if not (s := next((s for s in spans if s[0] < y and x < s[1]), None)) else 1 if x <= s[0] else 2
                      for x, y in offsets] for offsets, spans in zip(enc["offset_mapping"], batch["spans"])]
    enc.pop("offset_mapping")
    return enc

data = Dataset.from_list([json.loads(l) for l in open(a.train)]).map(encode, batched=True, remove_columns=["text", "spans"])
model = AutoModelForTokenClassification.from_pretrained(BASE, num_labels=3, id2label=dict(enumerate(LABELS)), label2id={l: i for i, l in enumerate(LABELS)})
args = TrainingArguments(a.out, per_device_train_batch_size=16, num_train_epochs=a.epochs, learning_rate=5e-5,
                         warmup_steps=75, logging_steps=200, save_strategy="no", report_to=[], seed=43)
started = time.time()
Trainer(model=model, args=args, train_dataset=data, data_collator=DataCollatorForTokenClassification(tok)).train()
print(f"train seconds {time.time() - started:.0f}")
model.save_pretrained(a.out); tok.save_pretrained(a.out)