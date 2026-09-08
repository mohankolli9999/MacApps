/// What restoring an artefact costs the user.
public struct Cost: Codable, Sendable, Equatable {
    public var seconds: Int?
    public var bytesToRefetch: Int64?

    public init(seconds: Int? = nil, bytesToRefetch: Int64? = nil) {
        self.seconds = seconds
        self.bytesToRefetch = bytesToRefetch
    }

    public static let free = Cost()
}

/// The proof that an artefact can be recreated after deletion.
public struct Recipe: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case ollamaPull
        case huggingFaceDownload
        case npmCleanInstall
        case homebrewFetch
        case pipDownload
        case rebuild
    }

    public var kind: Kind
    /// The exact command that restores this artefact, shown to the user verbatim.
    public var command: String
    public var parameters: [String: String]
    public var cost: Cost

    public init(kind: Kind, command: String, parameters: [String: String] = [:], cost: Cost = .free) {
        self.kind = kind
        self.command = command
        self.parameters = parameters
        self.cost = cost
    }

    /// A recipe is only proof if it names what to restore. `ollama pull <model>`
    /// restores nothing — the identifier died with the bytes. Unresolved
    /// `<placeholders>` therefore disqualify a recipe from being treated as proof.
    public var isConcrete: Bool {
        guard let open = command.firstIndex(of: "<") else { return true }
        return command[open...].firstIndex(of: ">") == nil
    }
}
