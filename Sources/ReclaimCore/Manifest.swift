import Foundation

public struct ManifestEntry: Codable, Sendable, Equatable {
    public var artefactID: String
    public var path: String
    public var tier: Tier
    public var bytesFreed: Int64
    public var recipe: Recipe
    public var timestamp: Date
    public var snapshotName: String?
    /// Set on a later append that re-states this reclaim once the user has run
    /// the recipe. The log stays append-only; nothing is ever rewritten.
    public var restoredAt: Date?

    public init(artefactID: String, path: String, tier: Tier, bytesFreed: Int64,
                recipe: Recipe, timestamp: Date = Date(), snapshotName: String? = nil,
                restoredAt: Date? = nil) {
        self.artefactID = artefactID
        self.path = path
        self.tier = tier
        self.bytesFreed = bytesFreed
        self.recipe = recipe
        self.timestamp = timestamp
        self.snapshotName = snapshotName
        self.restoredAt = restoredAt
    }

    /// Identifies the reclaim event, so a restore marker can be folded back onto
    /// the reclaim it refers to without rewriting the line.
    public var eventKey: String { "\(path)|\(timestamp.timeIntervalSince1970)" }
}

public struct ManifestRead: Sendable {
    public var entries: [ManifestEntry]
    /// Lines that could not be decoded. Skipping them keeps the rest of the log
    /// readable; counting them keeps the loss from being invisible.
    public var unreadableLines: Int
}

/// Append-only JSON Lines log of every reclaim, and the sole source of truth
/// for restores. One corrupt line must never cost the user the rest of the log.
public struct ManifestStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The one log the app and the CLI both write to. Naming it here rather than
    /// spelling the path at each call site: a site that drifts writes its
    /// restores somewhere nothing reads, which costs the user a way back.
    public static var standard: ManifestStore {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ManifestStore(url: base.appendingPathComponent("DiskReclaim/manifest.jsonl"))
    }

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

    public func all() throws -> [ManifestEntry] { try read().entries }

    public func read() throws -> ManifestRead {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ManifestRead(entries: [], unreadableLines: 0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(contentsOf: url, encoding: .utf8)

        var entries: [ManifestEntry] = []
        var unreadable = 0
        for line in text.split(separator: "\n") {
            if let entry = try? decoder.decode(ManifestEntry.self, from: Data(line.utf8)) {
                entries.append(entry)
            } else {
                unreadable += 1
            }
        }
        return ManifestRead(entries: entries, unreadableLines: unreadable)
    }
}
