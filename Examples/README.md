# Sample texts

Hand-written text for trying the tool by hand, in the shapes it is actually
pointed at. Every name, number and address here is invented.

These are not the test corpus. `Corpus/ja-baseline.json` is the ground truth the
regression tests run against; these files are for looking at output with your own
eyes, which is how the two defects in `docs/findings` were found.

```sh
cat Examples/1-incident.txt | privmask   # pipe it
Examples/use 1                           # or put it on the clipboard
```

| File | What it is for |
|---|---|
| `1-incident.txt` | The core case: an incident report with Japanese mixed into log lines. Names, a customer company, a phone number and an email, against commit hashes, a UUID, a version and a host:port that must all survive. |
| `2-customer.txt` | Dense personal data: name, address, postal code, three phone formats including full-width, email, My Number. Note the kana reading `（たかはし ゆみ）` is *not* detected — a known gap. |
| `3-false-positives.txt` | Nothing here should be masked, except that `田中` inside `田中式アルゴリズム` still is. IP addresses, ports, error codes, a SHA and a 12-digit order number must all survive. |
| `4-credentials.txt` | AWS, GitHub and OpenAI key shapes. `DB_PASSWORD=hunter2` is deliberately not matched: there is no generic password rule. |
| `5-english.txt` | English names, which come from `NLTagger` rather than the model. |
| `6-long.txt` | 2,300 characters — past the model's input cap. The tail keeps its real names and the truncation notice fires, which is what that limit looks like in practice. |

`3-false-positives.txt` matters as much as the rest. Over-masking corrupts the
text being shared, so a detector that improves recall by masking more is not
automatically better.
