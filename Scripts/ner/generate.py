# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = []
# ///
"""Template-generated training data for the name NER (#43). No model-written
text: templates and this code are the only authored parts, and every name comes
from SudachiDict, minus every name in the held-out corpora.

    uv run --managed-python Scripts/ner/generate.py .build/ner/train.jsonl --n 20000 --seed 43 --held-out Corpus/ja-names.json
    uv run --managed-python Scripts/ner/generate.py --check .build/ner/train.jsonl --held-out Corpus/ja-names.json
"""
import argparse, csv, importlib.util, io, json, random, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import nerlib  # noqa: E402
spec = importlib.util.spec_from_file_location("gs", HERE.parent / "generate-surnames.py")
gs = importlib.util.module_from_spec(spec); spec.loader.exec_module(gs)

# --- names -----------------------------------------------------------------
def name_pools(held: set[str]):
    surn, single, long_, given, kana_s, kana_g = (set() for _ in range(6))
    for r in csv.reader(io.StringIO(gs.fetch_lexicon())):
        if len(r) < 12:
            continue
        s, pos, reading = r[0], r[5:9], r[11]
        if pos == ["名詞", "固有名詞", "人名", "姓"] and gs.is_kanji(s):
            (single if len(s) == 1 else long_ if len(s) >= 4 else surn).add(s)
            if gs.is_katakana(reading): kana_s.add(reading)
        elif pos == ["名詞", "固有名詞", "人名", "名"] and gs.is_kanji(s) and len(s) >= 2:
            given.add(s)
            if gs.is_katakana(reading): kana_g.add(reading)
    low = {h.lower() for h in held}
    clean = lambda x: sorted(v for v in x if v not in held)
    # A reading is also written in hiragana and in romaji, and neither form may be held out.
    clean_kana = lambda x: sorted(v for v in x if v not in held and hira(v) not in held and romaji(v).lower() not in low)
    return (*map(clean, (surn, single, long_, given)), *map(clean_kana, (kana_s, kana_g)))

KANA = dict(zip("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポ",
    "a i u e o ka ki ku ke ko sa shi su se so ta chi tsu te to na ni nu ne no ha hi fu he ho ma mi mu me mo ya yu yo ra ri ru re ro wa o n ga gi gu ge go za ji zu ze zo da ji zu de do ba bi bu be bo pa pi pu pe po".split()))
SMALL = {"ャ": "ya", "ュ": "yu", "ョ": "yo"}
def romaji(k: str) -> str:
    out, i = "", 0
    while i < len(k):
        c = k[i]
        if c == "ッ" and i + 1 < len(k): out += KANA.get(k[i + 1], "")[:1]
        elif c == "ー": out += out[-1:]
        elif i + 1 < len(k) and k[i + 1] in SMALL and c in KANA:
            base = KANA[c]; out += (base[:-1] if base in ("shi", "chi", "ji") else base[:-1] + "y") + SMALL[k[i + 1]][-1]; i += 1
        elif c in KANA: out += KANA[c]
        i += 1
    return out
def hira(k: str) -> str: return "".join(chr(ord(c) - 0x60) if 0x30A1 <= ord(c) <= 0x30F6 else c for c in k)

# --- slots -----------------------------------------------------------------
# A name slot has a type. With probability NON_NAME it takes a natural
# non-name filler of that type instead of a name, unlabelled.
NON_NAME = 0.3
FILLERS = {
    "who": ["情報システム部", "インフラチーム", "当番エンジニア", "外部ベンダー", "品質保証チーム", "営業部", "サポート窓口", "開発チーム"],
    "acct": ["admin", "system", "batch", "svc-deploy", "root", "ci-runner", "monitor", "guest"],
    "mention": ["here", "channel", "all", "sre-oncall", "infra-team", "release-bot"],
    "addressee": ["皆さん", "お客様", "ご担当者様", "各位", "関係者各位", "チームの皆さん"],
}
HON = ["さん", "様", "氏", "", "", ""]

def person(rng, P) -> str:
    surn, single, long_, given, kana_s, kana_g = P
    f = rng.random()
    fam = rng.choice(surn) if f < 0.75 else rng.choice(single) if f < 0.9 else rng.choice(long_)
    k = rng.random()
    if k < 0.28: return fam + rng.choice([" ", "", "　"]) + rng.choice(given)
    if k < 0.52: return fam
    if k < 0.62: return rng.choice(given)
    if k < 0.69: return fam + " " + hira(rng.choice(kana_g))
    if k < 0.76: return hira(rng.choice(kana_g))
    if k < 0.84: return rng.choice(kana_s) + rng.choice([" ", ""]) + rng.choice(kana_g)
    if k < 0.94:
        a, b = romaji(rng.choice(kana_s)), romaji(rng.choice(kana_g))
        return rng.choice([f"{a}.{b}", f"{b}_{a}", f"{a.title()} {b.title()}", f"{b.title()} {a.title()}", a, f"{a}{rng.randint(1, 99)}"])
    return rng.choice(kana_s)

# --- templates -------------------------------------------------------------
# {who:...} etc. are name slots of that type; {ts} {svc} {id} {d} {co} {biz} fill text.
NAMED = [
    # incident
    "【障害報告】{biz}の遅延。一次対応: {who} / 二次対応: {who}", "担当は{who}{h}です。", "承認者: {who}", "復旧確認は{who}{h}、最終承認は{who}{h}が行いました。",
    "{who}{h}がロールバックを判断しました。", "現地調査は{who}が担当し、{who}が報告書をまとめました。", "エスカレーション先は{who}{h}です。",
    "原因調査: {who}（{d}日） / 恒久対策: {who}", "{who}{h}の指摘で{biz}の設定を見直した。", "記録は{who}が残しています。",
    # log
    "{ts} INFO  [{svc}] req={id} user={acct} action=login", "{ts} WARN  [{svc}] 承認待ち: 担当は{who}{h}", "{ts} ERROR [{svc}] 送信失敗 to={acct} code=550",
    "{ts} INFO  [{svc}] assignee={acct} reviewer={acct} status=open", "{ts} DEBUG [{svc}] owner={acct} job={id}", "{ts} INFO  [{svc}] 通知先 {who}{h} 宛にメール送信 id=msg-{id}",
    "audit: actor={acct} target={acct} op=grant", "{ts} WARN  [{svc}] {who}{h}の承認がタイムアウトしました",
    # slack
    "@{mention} {who}{h}が対応中です", "{who}{h}、確認お願いします。", "{who}{h}に引き継ぎました。", "{who}{h}が休みなので{who}{h}が代わりに対応します。",
    "{who}{h}、今日のリリース判定に参加できますか？", "了解です、{who}{h}に共有しておきます。", "{addressee}、{biz}の件は{who}{h}が見ています。",
    # markdown
    "| {who} | 設計レビュー | 2026-10-{d} |", "- [ ] {who}{h}: テスト計画の作成", "## 参加者\n- {who}\n- {who}{h}", "**レビュアー:** {who}",
    "メンテナ: {who}（{acct}@example.co.jp）", "| 担当 | {who} |\n| 期限 | 10/{d} |", "> {who}: {biz}は来週対応予定",
    # email
    "{addressee}\n\nいつもお世話になっております。{co}の{who}です。", "--\n{who}\n{co} 営業部", "From: {who} <{acct}@example.jp>",
    "{who}{h}\n\n先日の件、{who}よりご連絡いたします。", "ご不明な点は{who}までお問い合わせください。", "以上、{who}より。",
    # messy
    "{who}→{who}へ引継ぎ済", "{who}さんに確認済み、{who}は未確認", "担当:{who}／確認:{who}", "{who}{h}　から　連絡あり", "assignee={acct}　reviewer={who}",
]
UNNAMED = [
    # identifier-only lines
    "{ts} INFO  [{svc}] status=ok latency_ms={d}{d}", "kubectl -n {svc} rollout restart deploy/{svc}", "var config = require('./{svc}.yaml');",
    "/var/log/{svc}/error-{d}.log", "https://{svc}.internal.example/healthz", "v2.{d}.{d}", "{svc}-db-primary-01", "cache-main hit_ratio=0.9{d}",
    "export FOO_{d}=bar", "SELECT * FROM {svc}_events WHERE id = {d};", "mute.yaml を更新", "redis-cli -h cache-main INFO",
    # ordinary business sentences
    "月次の{biz}で請求の重複を検知した。", "{biz}のバッチが{d}分遅延しています。", "本日の{biz}は予定どおり完了しました。", "{biz}の仕様変更について確認したい。",
    "来週の{biz}は延期になりました。", "{biz}の集計結果に差分があります。", "台帳の{biz}を手動で照合したうえで再実行します。", "{biz}の手順書を更新しました。",
    "ご迷惑をおかけして申し訳ありません。", "承知しました。対応します。", "特に問題ありません。", "念のため再起動しておきます。",
    # roles where a name would sit
    "担当: {who_role}", "確認者: {who_role}", "承認者: {who_role}", "@{mention_only} 今日のリリース判定です", "{addressee_only}、ご確認ください。",
    # confusables
    "田中式アルゴリズムで再計算した。", "中村屋のカレーパンを差し入れ。", "東口改札付近の基地局で障害。", "森林公園側のアンテナは正常です。",
    "高橋ビル 3F 受付までお願いいたします。", "Grafana の search-overview を確認してください。", "Android アプリが起動時にクラッシュ。",
    "山田式の見積もりでは{d}人日です。", "佐藤製作所の部品が入荷しました。", "新宿第{d}データセンターで点検。",
]
BIZ = ["集計", "請求", "在庫", "障害対応", "リリース", "決済", "会計", "出荷", "請求書発行", "棚卸", "給与計算", "検索インデックス", "通知", "監査ログ"]
FILL = {
    "ts": lambda r: f"2026-09-{r.randint(1,30):02d}T{r.randint(0,23):02d}:{r.randint(0,59):02d}:00+09:00",
    "svc": lambda r: r.choice(["order-svc", "notify", "billing", "auth", "search-api", "inventory", "payments"]),
    "id": lambda r: f"{r.randrange(16**6):06x}", "d": lambda r: str(r.randint(1, 30)),
    "co": lambda r: r.choice(["株式会社サンプル商事", "サンプルシステムズ", "当社", "弊社"]),
    "biz": lambda r: r.choice(BIZ), "h": lambda r: r.choice(HON),
    "who_role": lambda r: r.choice(FILLERS["who"] + ["未定", "全員", "別途調整", "調整中"]), "mention_only": lambda r: r.choice(FILLERS["mention"]),
    "addressee_only": lambda r: r.choice(FILLERS["addressee"]),
}
SLOT_FALLBACK = {"who": "who", "acct": "acct", "mention": "mention", "addressee": "addressee"}

def render(rng, template, P):
    text, spans = "", []
    filled = False  # the last slot took a non-name filler, so no honorific may follow it
    for part in re.split(r"(\{\w+\})", template):
        key = part[1:-1] if part.startswith("{") else None
        if key in SLOT_FALLBACK:
            if key in ("mention", "addressee") or rng.random() < NON_NAME:
                text += rng.choice(FILLERS[key]); filled = True
            else:
                filled = False
                name = person(rng, P)
                if key == "acct":  # an account id is an ASCII name
                    name = romaji(rng.choice(P[4])) + rng.choice(["", ".", "_"]) + romaji(rng.choice(P[5]))
                spans.append([len(text), len(text) + len(name)]); text += name
        elif key == "h":
            text += "" if filled else FILL["h"](rng)
        elif key in FILL:
            text += FILL[key](rng)
        else:
            text += part
    return text, spans

def generate(n: int, seed: int, held: set[str]):
    rng, P = random.Random(seed), name_pools(held)
    for _ in range(n):
        if rng.random() < 0.25:   # a sample with no name at all; filled slots add more
            lines = [render(rng, rng.choice(UNNAMED), P) for _ in range(rng.randint(1, 4))]
        else:
            lines = [render(rng, rng.choice(NAMED if rng.random() < 0.7 else UNNAMED), P) for _ in range(rng.randint(1, 4))]
        text, spans = "", []
        for line, sp in lines:
            if text: text += "\n"
            spans += [[a + len(text), b + len(text)] for a, b in sp]
            text += line
        yield {"text": text, "spans": spans}

def check(path: str, held: set[str]) -> None:
    rows = [json.loads(l) for l in open(path)]
    names = [r["text"][a:b] for r in rows for a, b in r["spans"]]
    low = {h.lower() for h in held}
    leaked = {n for n in names if n.lower() in low or any(t.lower() in low for t in re.split(r"[\s　・._\-]+", n) if t)}
    assert not leaked, f"held-out names in training data: {sorted(leaked)[:10]}"
    assert all(0 <= a < b <= len(r["text"]) for r in rows for a, b in r["spans"]), "span out of range"
    empty = sum(1 for r in rows if not r["spans"]) / len(rows)
    assert 0.30 <= empty <= 0.45, f"{empty:.0%} of samples have no name; expected 30-45%"
    print(f"check passed: {len(rows)} samples, {len(names)} names, {empty:.0%} with none")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?"); ap.add_argument("--check"); ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=43); ap.add_argument("--held-out", nargs="+", required=True)
    a = ap.parse_args()
    held = nerlib.held_out_names(a.held_out)
    if a.check:
        check(a.check, held)
    else:
        with open(a.out, "w") as f:
            for row in generate(a.n, a.seed, held):
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        check(a.out, held)