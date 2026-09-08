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

public enum ValidationRegistry {
    /// Resolve a catalogue `validator` name. Returns nil for unrecognised names —
    /// there is deliberately no permissive default.
    public static func validator(named name: String, recipeKind: Recipe.Kind?) -> RecipeValidator? {
        switch name {
        case "none":
            return NeverProvenValidator(reason: "no restore recipe exists for this artefact")
        case "alwaysProven":
            guard let kind = recipeKind else { return nil }
            return AlwaysProvenValidator(recipe: Recipe(kind: kind, command: command(for: kind)))
        case "ollama":
            return CommandValidator(executable: "/usr/local/bin/ollama", arguments: ["list"],
                                    recipe: Recipe(kind: .ollamaPull, command: "ollama pull <model>"))
        case "huggingface":
            return CommandValidator(executable: "/usr/bin/curl",
                                    arguments: ["-sf", "-o", "/dev/null", "https://huggingface.co"],
                                    recipe: Recipe(kind: .huggingFaceDownload,
                                                   command: "huggingface-cli download <repo> --revision <rev>"))
        default:
            return nil
        }
    }

    private static func command(for kind: Recipe.Kind) -> String {
        switch kind {
        case .ollamaPull: "ollama pull <model>"
        case .huggingFaceDownload: "huggingface-cli download <repo>"
        case .npmCleanInstall: "npm ci"
        case .homebrewFetch: "brew fetch <formula>"
        case .pipDownload: "pip download <package>"
        case .rebuild: "rebuild the project"
        }
    }
}
