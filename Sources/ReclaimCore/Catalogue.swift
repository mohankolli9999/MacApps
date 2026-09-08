import Foundation

public struct CatalogueEntry: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var path: String
    public var tier: Tier
    public var recipeKind: Recipe.Kind?
    public var validator: String
    /// The restore instruction, for validators that cannot derive one by
    /// inspecting the disk. Kept as catalogue data so wording ships without a release.
    public var restoreNote: String?

    public init(id: String, displayName: String, path: String, tier: Tier,
                recipeKind: Recipe.Kind? = nil, validator: String, restoreNote: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.tier = tier
        self.recipeKind = recipeKind
        self.validator = validator
        self.restoreNote = restoreNote
    }

    /// `path` with a leading tilde resolved against the current home directory.
    public var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }
}

public struct Catalogue: Codable, Sendable {
    public var version: Int
    public var entries: [CatalogueEntry]

    public func entry(id: String) -> CatalogueEntry? {
        entries.first { $0.id == id }
    }

    public static func load(from data: Data) throws -> Catalogue {
        try JSONDecoder().decode(Catalogue.self, from: data)
    }

    public static func bundled() throws -> Catalogue {
        guard let url = Bundle.module.url(forResource: "catalogue", withExtension: "json") else {
            throw ScanError.notFound("catalogue.json")
        }
        return try load(from: Data(contentsOf: url))
    }
}
