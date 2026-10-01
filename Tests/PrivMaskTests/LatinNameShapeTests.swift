import Testing

@testable import PrivMask

/// What the model returns in Latin script is mostly not English names. On the
/// name corpus it returned `orders-db`, `lb-orders-01` and `nightly-sync-12` as
/// personal names, and nothing checked them. See #32.
@Suite("Latin text the model calls a name")
struct LatinNameShapeTests {
    @Test(
        "Romaji names, including user ids built from them, are accepted",
        arguments: [
            "funatsu.keigo", "Mizuki_Sagasaki", "Hiroki Kotani", "IiiTake_01",
            "wakatanabe-kansuke", "habutani.kenji", "Akashio", "shijuuin",
            "Ｈｉｒｏｋｉ",  // full-width
        ]
    )
    func acceptsRomaji(_ name: String) {
        #expect(LatinNameShape.isNameShaped(name))
    }

    /// `Michael O'Connor` is found by the model and not by NLTagger, so a
    /// romaji-only rule would stop masking it.
    @Test(
        "Western personal names are accepted",
        arguments: ["John Smith", "Michael O'Connor", "Mary-Jane Lee", "McDonald", "Sarah Johnson"]
    )
    func acceptsWesternNames(_ name: String) {
        #expect(LatinNameShape.isNameShaped(name))
    }

    /// Every one of these was returned by the model as a personal name on the
    /// name corpus.
    @Test(
        "Hostnames, job names and file names are rejected",
        arguments: [
            "orders-db", "orders-db-b", "orders-api", "orders-worker", "lb-orders-01",
            "ORD-DB-PRIMARY-DOWN", "ORD-OPS", "grafana.internal.example",
            "postgresql-15-main.log", "db-primary-01", "nightly-sync-12",
            "search-api", "sales-rollup", "sales_202609.csv",
        ]
    )
    func rejectsIdentifiers(_ span: String) {
        #expect(!LatinNameShape.isNameShaped(span))
    }

    @Test("A string of digits and separators alone is not a name")
    func rejectsDigitsOnly() {
        #expect(!LatinNameShape.isNameShaped("01_02"))
        #expect(!LatinNameShape.isNameShaped(""))
    }
}
