import Foundation

public struct RestorePlan: Sendable, Equatable {
    public var entry: ManifestEntry
    /// The exact command that restores this artefact.
    public var command: String
}

public struct RestoreEngine: Sendable {
    private let manifest: ManifestStore

    public init(manifest: ManifestStore) { self.manifest = manifest }

    public func plan(for path: String) throws -> RestorePlan? {
        try manifest.all()
            .last { $0.path == path }
            .map { RestorePlan(entry: $0, command: $0.recipe.command) }
    }

    public func planAll() throws -> [RestorePlan] {
        try manifest.all().map { RestorePlan(entry: $0, command: $0.recipe.command) }
    }
}
