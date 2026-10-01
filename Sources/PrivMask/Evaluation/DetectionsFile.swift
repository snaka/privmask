import Foundation

/// The personal names one system found in each sample of a corpus.
///
/// Every system being compared writes this: privmask through
/// `FoundationModelProbe`, and Opus, NER or a Jev-style classifier through
/// whatever harness runs them. `NameScore` then scores them all the same way.
/// See #28.
public struct DetectionsFile: Codable, Sendable {
    public struct Name: Codable, Sendable, Equatable {
        public let text: String
        /// UTF-16 offset into the sample text, as `NSString` counts. Optional,
        /// because a system that returns only strings cannot give one; the text
        /// then counts as found at every place it occurs.
        public let location: Int?
        public let length: Int?

        public init(text: String, location: Int? = nil, length: Int? = nil) {
            self.text = text
            self.location = location
            self.length = length
        }
    }

    public struct SampleDetections: Codable, Sendable {
        public let names: [Name]
        /// Strings a filter threw away before `names` was produced. Only
        /// privmask writes this; it is what tells a miss the model never
        /// returned from one the filter discarded.
        public let rejected: [String]?

        public init(names: [Name], rejected: [String]? = nil) {
            self.names = names
            self.rejected = rejected
        }
    }

    public let system: String
    /// Keyed by corpus sample id. A sample with no entry was never examined.
    public let samples: [String: SampleDetections]

    public init(system: String, samples: [String: SampleDetections]) {
        self.system = system
        self.samples = samples
    }

    public static func decode(_ data: Data) throws -> DetectionsFile {
        try JSONDecoder().decode(DetectionsFile.self, from: data)
    }

    public static func load(contentsOf url: URL) throws -> DetectionsFile {
        try decode(Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)
    }
}
