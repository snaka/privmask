import Foundation

/// Common Japanese family names, used to *verify* candidates the language model
/// returns — never to detect them.
///
/// The distinction matters. As a detector this list would only ever find names
/// somebody already thought of, which is the weakness the model exists to fix.
/// As a check on the model's output it costs nothing and rejects the words the
/// model reaches for when a text contains no names at all: `緊急連絡先`,
/// `全角表記`, `内線` do not begin with a family name, and `サポート窓口` is not
/// even written the way a name is written.
///
/// The list is deliberately not exhaustive. A rare surname that is missing costs
/// one false negative on a low-confidence finding the user still sees flagged;
/// a bloated list costs precision.
public enum JapaneseSurnames {
    /// Kanji family names, including those common among Chinese and Korean
    /// residents of Japan.
    public static let kanji: Set<String> = [
        "佐藤", "鈴木", "高橋", "田中", "伊藤", "渡辺", "渡邊", "渡部", "山本", "中村",
        "小林", "加藤", "吉田", "山田", "佐々木", "山口", "松本", "井上", "木村", "林",
        "斎藤", "斉藤", "齋藤", "清水", "山崎", "山﨑", "阿部", "森", "池田", "橋本",
        "山下", "石川", "中島", "前田", "藤田", "後藤", "小川", "岡田", "村上", "長谷川",
        "近藤", "石井", "坂本", "遠藤", "藤井", "青木", "福田", "三浦", "西村", "藤原",
        "太田", "松田", "原田", "岡本", "中川", "中野", "小野", "田村", "竹内", "金子",
        "和田", "中山", "石田", "上田", "森田", "原", "柴田", "酒井", "工藤", "横山",
        "宮崎", "宮本", "内田", "高木", "安藤", "島田", "谷口", "大野", "高田", "丸山",
        "今井", "河野", "藤本", "村田", "武田", "上野", "杉山", "増田", "小島", "小山",
        "大塚", "平野", "菅原", "久保", "松井", "千葉", "岩崎", "桜井", "木下", "野口",
        "松尾", "菊地", "菊池", "野村", "新井", "佐野", "市川", "水野", "大谷", "望月",
        "川崎", "秋山", "星野", "黒田", "吉川", "川口", "関", "平田", "岩田", "中西",
        "服部", "樋口", "福島", "川上", "永井", "松岡", "大西", "田口", "山内", "松浦",
        "荒木", "熊谷", "早川", "篠原", "西田", "中田", "小松", "土屋", "杉本", "堀",
        "大久保", "本田", "浅野", "白石", "森本", "古川", "飯田", "久保田", "河合", "岡崎",
        "内藤", "堀内", "安田", "沢田", "澤田", "高野", "西川", "北村", "小池", "宇野",
        "深沢", "深澤", "須藤", "南", "多田", "米田", "西尾", "青山",
        "李", "金", "朴", "崔", "鄭", "姜", "趙", "尹", "張", "王", "陳", "劉", "楊",
        "黄", "呉", "徐", "孫", "高", "郭", "沈",
    ]

    /// Katakana readings of the most common family names, for names written in
    /// katakana rather than kanji.
    public static let katakana: Set<String> = [
        "サトウ", "スズキ", "タカハシ", "タナカ", "イトウ", "ワタナベ", "ヤマモト", "ナカムラ",
        "コバヤシ", "カトウ", "ヨシダ", "ヤマダ", "ササキ", "ヤマグチ", "マツモト", "イノウエ",
        "キムラ", "ハヤシ", "サイトウ", "シミズ", "ヤマザキ", "アベ", "モリ", "イケダ",
        "ハシモト", "ヤマシタ", "イシカワ", "ナカジマ", "マエダ", "フジタ", "ゴトウ", "オガワ",
        "オカダ", "ムラカミ", "ハセガワ", "コンドウ", "イシイ", "サカモト", "エンドウ", "フジイ",
        "アオキ", "フクダ", "ミウラ", "ニシムラ", "フジワラ", "オオタ", "マツダ", "ハラダ",
        "オカモト", "ナカガワ", "ナカノ", "オノ", "タムラ", "タケウチ", "カネコ", "ワダ",
        "ナカヤマ", "イシダ", "ウエダ", "モリタ", "スガワラ", "キノシタ", "ノムラ", "マツオ",
    ]

    /// True when `text` begins with a family name from either list.
    ///
    /// Kanji surnames are one to three characters, so only those prefixes are
    /// tried. Katakana names are matched on their first whitespace-separated
    /// token, since a katakana full name is usually written 「ヤマダ タロウ」.
    public static func beginsWithSurname(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        for length in stride(from: min(3, trimmed.count), through: 1, by: -1) {
            let prefix = String(trimmed.prefix(length))
            if kanji.contains(prefix) { return true }
        }

        let firstToken = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        return katakana.contains(firstToken) || katakana.contains(trimmed)
    }
}
