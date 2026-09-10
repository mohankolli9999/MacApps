import Foundation
import Observation
import ReclaimCore

@MainActor
@Observable
final class ScanModel {
    struct Row: Identifiable, Equatable {
        let id: String
        let displayName: String
        let path: String
        var tier: Tier
        var reclaimableBytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var recipe: Recipe?
        var note: String?
        var isMeasuring: Bool = true

        var isReclaimable: Bool { tier <= Tier.automaticCeiling && recipe != nil }
    }

    private(set) var rows: [Row] = []
    private(set) var isScanning = false
    private(set) var freeBytes: Int64 = 0
    private(set) var lastReclaim: String?
    private(set) var history: [RestorePlan] = []
    private(set) var unreadableHistoryLines = 0
    var selection: String?

    private let entries: [CatalogueEntry]
    private let manifest: ManifestStore
    private var scanTask: Task<Void, Never>?

    init() {
        entries = (try? Catalogue.bundled())?.entries ?? []
        manifest = .standard
    }

    var reclaimable: [Row] { rows.filter(\.isReclaimable) }
    var locked: [Row] { rows.filter { !$0.isReclaimable } }
    /// What emptying these caches would return. Not what they occupy: a cache
    /// cloned from something outside it occupies blocks it cannot give back.
    var reclaimableBytes: Int64 { reclaimable.reduce(0) { $0 + $1.reclaimableBytes } }
    var lockedBytes: Int64 { locked.reduce(0) { $0 + $1.reclaimableBytes } }
    var measuredBytes: Int64 { rows.reduce(0) { $0 + $1.reclaimableBytes } }
    var selectedRow: Row? { rows.first { $0.id == selection } }
    var reclaimedBytes: Int64 { history.reduce(0) { $0 + $1.entry.bytesFreed } }

    /// The log records the catalogue id, which is a key, not a name. Entries for
    /// caches the catalogue no longer knows about still have to render.
    func displayName(forArtefact id: String) -> String {
        entries.first { $0.id == id }?.displayName
            ?? id.replacingOccurrences(of: ".", with: " ")
    }

    func refreshHistory() {
        unreadableHistoryLines = (try? manifest.read().unreadableLines) ?? 0
        history = (try? RestoreEngine(manifest: manifest).history()) ?? []
    }

    /// Bookkeeping only. The recorded command is shown and copied, never run:
    /// handing a string read off disk to a shell is a command-injection sink,
    /// and the user running it themselves is also the honest division of trust.
    func markRestored(_ plan: RestorePlan) {
        try? RestoreEngine(manifest: manifest).markRestored(plan.entry)
        refreshHistory()
    }

    func scan() {
        scanTask?.cancel()
        refreshFreeSpace()

        let present = entries.filter { FileManager.default.fileExists(atPath: $0.expandedPath) }
        rows = present.map {
            Row(id: $0.id, displayName: $0.displayName, path: $0.expandedPath, tier: $0.tier)
        }
        guard !present.isEmpty else { isScanning = false; return }
        isScanning = true

        scanTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for entry in present {
                    let id = entry.id
                    let url = URL(fileURLWithPath: entry.expandedPath)
                    group.addTask {
                        // Runs off the main actor. Progress is already throttled
                        // by the scanner, so this hop happens ~16x a second per
                        // cache rather than once per file.
                        let total = try? DiskScanner.measure(url, progressInterval: 0.06) { partial in
                            Task { @MainActor in self.apply(id, partial, finished: false) }
                        }
                        await MainActor.run { self.apply(id, total ?? .zero, finished: true) }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await validate(present)
            isScanning = false
        }
    }

    private func apply(_ id: String, _ measurement: DiskScanner.Measurement, finished: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        // Progress hops can land out of order; a block must never shrink mid-scan.
        rows[i].reclaimableBytes = max(rows[i].reclaimableBytes, measurement.reclaimableBytes)
        rows[i].logicalBytes = max(rows[i].logicalBytes, measurement.logicalBytes)
        rows[i].fileCount = max(rows[i].fileCount, measurement.fileCount)
        if finished { rows[i].isMeasuring = false }
    }

    private func validate(_ entries: [CatalogueEntry]) async {
        for entry in entries {
            guard let i = rows.firstIndex(where: { $0.id == entry.id }) else { continue }
            let artefact = Artefact(id: entry.id,
                                    path: URL(fileURLWithPath: entry.expandedPath),
                                    logicalBytes: rows[i].logicalBytes,
                                    reclaimableBytes: rows[i].reclaimableBytes,
                                    tier: entry.tier)

            let result: ValidationResult
            if let validator = ValidationRegistry.validator(for: entry) {
                result = await Task.detached { await validator.validate(artefact) }.value
            } else {
                result = .unproven(reason: "no validator named '\(entry.validator)' exists")
            }

            guard let j = rows.firstIndex(where: { $0.id == entry.id }) else { continue }
            let validated = applyValidation(artefact, result)
            rows[j].tier = validated.tier
            rows[j].recipe = validated.recipe
            switch result {
            case .unproven(let reason):
                rows[j].note = reason
            case .proven(let recipe):
                rows[j].note = recipe.isConcrete
                    ? nil
                    : "the restore command is still a template, so it proves nothing"
            }
        }
    }

    func reclaim(_ ids: Set<String>) async {
        let targets = rows.filter { ids.contains($0.id) && $0.isReclaimable }
        guard !targets.isEmpty else { return }

        let artefacts = targets.map {
            Artefact(id: $0.id, path: URL(fileURLWithPath: $0.path),
                     logicalBytes: $0.logicalBytes, reclaimableBytes: $0.reclaimableBytes,
                     tier: $0.tier, recipe: $0.recipe)
        }
        let store = manifest
        let outcomes = await Task.detached { () -> [(Artefact, ExecutionOutcome)] in
            (try? ReclaimExecutor(manifest: store, mode: .reclaim).execute(artefacts)) ?? []
        }.value

        var freed: Int64 = 0
        var skipped = 0
        for (_, outcome) in outcomes {
            switch outcome {
            case .reclaimed(let bytes): freed += bytes
            case .skipped: skipped += 1
            case .wouldReclaim: break
            }
        }
        lastReclaim = skipped == 0
            ? "Freed \(humanBytes(freed))."
            : "Freed \(humanBytes(freed)). \(skipped) skipped as unprovable."
        selection = nil
        refreshHistory()
        scan()
    }

    private func refreshFreeSpace() {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
