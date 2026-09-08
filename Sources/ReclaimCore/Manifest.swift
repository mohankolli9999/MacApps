import Foundation

public struct ManifestEntry: Codable, Sendable, Equatable {
    public var artefactID: String
    public var path: String
    public var tier: Tier
    public var bytesFreed: Int64
    public var recipe: Recipe
    public var timestamp: Date
    public var snapshotName: String?

    public init(artefactID: String, path: String, tier: Tier, bytesFreed: Int64,
                recipe: Recipe, timestamp: Date = Date(), snapshotName: String? = nil) {
        self.artefactID = artefactID
        self.path = path
        self.tier = tier
        self.bytesFreed = bytesFreed
        self.recipe = recipe
        self.timestamp = timestamp
        self.snapshotName = snapshotName
    }
}

/// Append-only JSON Lines log of every reclaim, and the sole source of truth
/// for restores. One corrupt line must never cost the user the rest of the log.
public struct ManifestStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(_ entry: ManifestEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    public func all() throws -> [ManifestEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(ManifestEntry.self, from: Data(line.utf8))
        }
    }
}
