import Foundation

public enum ExecutionMode: Sendable, Equatable {
    case dryRun
    case reclaim
}

public enum ExecutionOutcome: Sendable, Equatable {
    case wouldReclaim(Int64)
    case reclaimed(Int64)
    case skipped(reason: String)
}

/// Named `ReclaimExecutor` rather than `Executor` because Swift concurrency
/// exports an `Executor` protocol, and the collision makes the type
/// unconstructable at call sites.
public struct ReclaimExecutor: Sendable {
    private let manifest: ManifestStore
    private let mode: ExecutionMode

    public init(manifest: ManifestStore, mode: ExecutionMode = .dryRun) {
        self.manifest = manifest
        self.mode = mode
    }

    public func execute(_ artefacts: [Artefact]) throws -> [(Artefact, ExecutionOutcome)] {
        var results: [(Artefact, ExecutionOutcome)] = []
        for artefact in artefacts {
            results.append((artefact, try execute(artefact)))
        }
        return results
    }

    private func execute(_ artefact: Artefact) throws -> ExecutionOutcome {
        guard artefact.tier <= Tier.automaticCeiling else {
            return .skipped(reason: "tier \(artefact.tier.rawValue) is never actioned automatically")
        }
        guard let recipe = artefact.recipe else {
            return .skipped(reason: "no validated restore recipe")
        }
        guard mode == .reclaim else {
            return .wouldReclaim(artefact.physicalBytes)
        }

        try FileManager.default.removeItem(at: artefact.path)

        try manifest.append(ManifestEntry(artefactID: artefact.id,
                                          path: artefact.path.path,
                                          tier: artefact.tier,
                                          bytesFreed: artefact.physicalBytes,
                                          recipe: recipe))
        return .reclaimed(artefact.physicalBytes)
    }
}
