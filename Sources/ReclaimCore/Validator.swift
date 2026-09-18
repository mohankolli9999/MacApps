import Foundation

public enum ValidationResult: Sendable, Equatable {
    case proven(Recipe)
    case unproven(reason: String)
}

public protocol RecipeValidator: Sendable {
    func validate(_ artefact: Artefact) async -> ValidationResult
}

/// The product guarantee, in one function: anything we cannot prove we can
/// restore becomes irreplaceable, and irreplaceable is never actioned.
public func applyValidation(_ artefact: Artefact, _ result: ValidationResult) -> Artefact {
    var out = artefact
    switch result {
    case .proven(let recipe) where recipe.isConcrete:
        out.recipe = recipe
    case .proven, .unproven:
        out.recipe = nil
        out.tier = .irreplaceable
    }
    return out
}

public struct AlwaysProvenValidator: RecipeValidator {
    private let recipe: Recipe
    public init(recipe: Recipe) { self.recipe = recipe }
    public func validate(_ artefact: Artefact) async -> ValidationResult { .proven(recipe) }
}

public struct NeverProvenValidator: RecipeValidator {
    private let reason: String
    public init(reason: String) { self.reason = reason }
    public func validate(_ artefact: Artefact) async -> ValidationResult { .unproven(reason: reason) }
}

/// Proves a recipe by running a real command and requiring exit status 0.
public struct CommandValidator: RecipeValidator {
    private let executable: String
    private let arguments: [String]
    private let recipe: Recipe

    public init(executable: String, arguments: [String], recipe: Recipe) {
        self.executable = executable
        self.arguments = arguments
        self.recipe = recipe
    }

    public func validate(_ artefact: Artefact) async -> ValidationResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .unproven(reason: "\(executable) is not available")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unproven(reason: "\(executable) failed to launch: \(error)")
        }
        guard process.terminationStatus == 0 else {
            return .unproven(reason: "\(executable) exited \(process.terminationStatus)")
        }
        return .proven(recipe)
    }
}

/// Names every model on disk before it is deleted, because afterwards there is
/// nothing left to read the names from.
public struct OllamaValidator: RecipeValidator {
    public init() {}

    public func validate(_ artefact: Artefact) async -> ValidationResult {
        guard Executables.find("ollama") != nil else {
            return .unproven(reason: "ollama is not installed, so its models could not be refetched")
        }
        guard let recipe = OllamaExtractor.recipe(root: artefact.path) else {
            return .unproven(reason: "no readable model manifests, so the models cannot be named")
        }
        return .proven(recipe)
    }
}

public enum ValidationRegistry {
    /// Resolve a catalogue entry's validator. Returns nil for unrecognised names —
    /// there is deliberately no permissive default.
    public static func validator(for entry: CatalogueEntry) -> RecipeValidator? {
        switch entry.validator {
        case "none":
            return NeverProvenValidator(reason: "no restore recipe exists for this artefact")

        case "ollama":
            return OllamaValidator()

        // Pure download caches: the tool refetches on next use, so the correct
        // restore instruction is genuinely "do nothing".
        case "automatic":
            guard let note = entry.restoreNote else { return nil }
            return AlwaysProvenValidator(recipe: Recipe(kind: .automatic, command: note, cost: .free))

        case "rebuild":
            guard let note = entry.restoreNote else { return nil }
            return AlwaysProvenValidator(recipe: Recipe(kind: .rebuild, command: note))

        case "huggingface":
            return NeverProvenValidator(
                reason: "the repos in this cache cannot be named yet, so it cannot be proven restorable")

        case "alwaysProven":
            guard let kind = entry.recipeKind else { return nil }
            return AlwaysProvenValidator(recipe: Recipe(kind: kind, command: template(for: kind)))

        default:
            return nil
        }
    }

    /// Deliberately still templates. Anything routed here fails `isConcrete` and
    /// downgrades to irreplaceable, which is the correct outcome until a real
    /// extractor exists for that artefact.
    private static func template(for kind: Recipe.Kind) -> String {
        switch kind {
        case .ollamaPull: "ollama pull <model>"
        case .huggingFaceDownload: "huggingface-cli download <repo>"
        case .npmCleanInstall: "npm ci"
        case .homebrewFetch: "brew fetch <formula>"
        case .pipDownload: "pip download <package>"
        case .rebuild: "rebuild the project"
        case .automatic: "No action needed."
        case .trash: "In Finder, open the Trash and choose Put Back"
        }
    }
}
