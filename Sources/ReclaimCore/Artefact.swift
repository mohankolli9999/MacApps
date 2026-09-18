import Foundation

/// A discovered, classified chunk of reclaimable disk.
public struct Artefact: Sendable, Equatable {
    /// Catalogue entry id, e.g. "ollama.models".
    public var id: String
    public var path: URL
    /// Sum of file sizes.
    public var logicalBytes: Int64
    /// Blocks actually allocated, with hardlinks counted once.
    public var reclaimableBytes: Int64
    public var tier: Tier
    public var recipe: Recipe?

    public init(id: String, path: URL, logicalBytes: Int64, reclaimableBytes: Int64, tier: Tier, recipe: Recipe? = nil) {
        self.id = id
        self.path = path
        self.logicalBytes = logicalBytes
        self.reclaimableBytes = reclaimableBytes
        self.tier = tier
        self.recipe = recipe
    }
}
