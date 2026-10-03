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
        arguments: [
            "John Smith", "Michael O'Connor", "Mary-Jane Lee", "Sarah Johnson", "Emma Brown", "Wei Zhang", "Priya Patel",
            // Tagged a person read alone but not in the probe sentence. See #40.
            "Seungwoo Song", "Meera Mehta",
        ]
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

    /// Shaped like a Western name, but product and team names. The model
    /// returned the first four as personal names on the name corpus; the rest
    /// show the check needs no list. See #40.
    @Test(
        "Product and team names shaped like a Western name are rejected",
        arguments: [
            "Android", "Firebase Crashlytics", "Google Play Console", "Mobile Platform",
            "Platform Team", "Kubernetes", "Datadog", "Visual Studio",
        ]
    )
    func rejectsProductNames(_ span: String) {
        #expect(!LatinNameShape.isNameShaped(span))
    }

    @Test("A string of digits and separators alone is not a name")
    func rejectsDigitsOnly() {
        #expect(!LatinNameShape.isNameShaped("01_02"))
        #expect(!LatinNameShape.isNameShaped(""))
    }

    /// An initial or a one-letter suffix sits beside a romaji name in user ids
    /// and signatures. Python's NER masked all three. See #46.
    @Test("A single letter beside a romaji name is ignored", arguments: ["S. Suguri", "koyaba_j", "nagatsuta.m"])
    func acceptsInitials(_ name: String) {
        #expect(LatinNameShape.readsAsRomaji(name))
    }

    @Test("Single letters alone do not read as romaji", arguments: ["S. K", "a", "orders-db"])
    func rejectsLettersAlone(_ span: String) {
        #expect(!LatinNameShape.readsAsRomaji(span))
    }
}
