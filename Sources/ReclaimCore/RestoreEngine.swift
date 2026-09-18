import Foundation

public struct RestorePlan: Sendable, Equatable, Identifiable {
    public var entry: ManifestEntry
    /// The exact command that restores this artefact.
    public var command: String
    public var isRestored: Bool = false

    public var id: String { entry.eventKey }
}

public struct RestoreEngine: Sendable {
    private let manifest: ManifestStore

    public init(manifest: ManifestStore) { self.manifest = manifest }

    public func plan(for path: String) throws -> RestorePlan? {
        try manifest.all()
            .last { $0.path == path }
            .map { RestorePlan(entry: $0, command: $0.recipe.command) }
    }

    /// Every reclaim ever recorded, newest first, with any later restore marker
    /// folded back onto the reclaim it refers to.
    public func history() throws -> [RestorePlan] {
        var byEvent: [String: RestorePlan] = [:]
        for entry in try manifest.all() {
            let restored = entry.restoredAt != nil
            if var known = byEvent[entry.eventKey] {
                known.isRestored = known.isRestored || restored
                byEvent[entry.eventKey] = known
            } else {
                byEvent[entry.eventKey] = RestorePlan(entry: entry,
                                                      command: entry.recipe.command,
                                                      isRestored: restored)
            }
        }
        return byEvent.values.sorted { $0.entry.timestamp > $1.entry.timestamp }
    }

    /// Records that the user has run the recipe. Deliberately does not execute
    /// it: a command read back off disk is never handed to a shell.
    public func markRestored(_ entry: ManifestEntry) throws {
        var marker = entry
        marker.restoredAt = Date()
        try manifest.append(marker)
    }
}
