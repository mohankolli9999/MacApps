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
        guard let url = bundledURL else { throw ScanError.notFound("catalogue.json") }
        return try load(from: Data(contentsOf: url))
    }

    /// Deliberately not `Bundle.module`, which has two defects that compound.
    ///
    /// Its generated accessor looks for the resource bundle in
    /// `Bundle.main.bundleURL` — for an app, the `.app` root. `codesign` seals
    /// `Contents/` and nothing standing beside it, so a resource bundle there
    /// leaves the app permanently unsignable: no seal, no `_CodeSignature`, and
    /// `syspolicy_check` grading it fatal.
    ///
    /// Its only other candidate is an absolute path into the `.build` directory
    /// of whoever compiled the binary. That ships their home directory inside
    /// the executable, and because it resolves on the build machine it would let
    /// a broken lookup here launch fine for the author and fail for everyone
    /// else. Naming the accessor anywhere keeps that string; not naming it lets
    /// the linker drop the static and the path with it.
    private static var bundledURL: URL? {
        Bundle.main.resourceURL
            .map { $0.appendingPathComponent("DiskReclaim_ReclaimCore.bundle") }
            .flatMap(Bundle.init(url:))?
            .url(forResource: "catalogue", withExtension: "json")
    }
}
