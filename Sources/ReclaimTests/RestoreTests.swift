import Foundation
import ReclaimCore

@MainActor func runRestoreTests(_ t: Harness) {
    t.section("Restore engine")

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("reclaim-restore-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = ManifestStore(url: dir.appendingPathComponent("m.jsonl"))
    try? store.append(ManifestEntry(artefactID: "ollama.models", path: "/fixture/models",
                                    tier: .exact,
                                    bytesFreed: 14_000_000_000,
                                    recipe: Recipe(kind: .ollamaPull,
                                                   command: "ollama pull llama3:8b",
                                                   parameters: ["digest": "sha256:abc"])))

    let engine = RestoreEngine(manifest: store)

    let plan = try? engine.plan(for: "/fixture/models")
    t.expect((plan ?? nil) != nil, "plan exists for a reclaimed path")
    t.equal((plan ?? nil)?.command, "ollama pull llama3:8b", "plan emits the exact recorded command")

    let none = try? engine.plan(for: "/never/reclaimed")
    t.expect((none ?? nil) == nil, "no plan for a path never reclaimed")

    t.equal((try? engine.planAll().count) ?? -1, 1, "planAll returns every recorded reclaim")

    t.section("Round trip")
    // Full cycle: create -> classify -> validate -> reclaim -> restore command recovered.
    let victim = dir.appendingPathComponent("cache")
    try? fm.createDirectory(at: victim, withIntermediateDirectories: true)
    try? Data(repeating: 0x43, count: 2048).write(to: victim.appendingPathComponent("blob"))

    let measured = (try? DiskScanner.measure(victim)) ?? .zero
    t.equal(measured.fileCount, 1, "round trip: fixture measured")

    let catJSON = """
    {"version":1,"entries":[{"id":"npm.cache","displayName":"npm cache",
      "path":"\(victim.path)","tier":"exact","recipeKind":"npmCleanInstall",
      "validator":"alwaysProven"}]}
    """.data(using: .utf8)!
    let cat = try! Catalogue.load(from: catJSON)
    let classified = Classifier(catalogue: cat).classify(path: victim, measurement: measured)
    t.equal(classified.tier, .exact, "round trip: classified as exact")

    let validated = applyValidation(classified,
        .proven(Recipe(kind: .npmCleanInstall, command: "npm ci")))
    t.expect(validated.recipe != nil, "round trip: recipe attached")

    let rtStore = ManifestStore(url: dir.appendingPathComponent("rt.jsonl"))
    let outcomes = (try? ReclaimExecutor(manifest: rtStore, mode: .reclaim).execute([validated])) ?? []
    if case .reclaimed = outcomes.first?.1 {
        t.expect(true, "round trip: reclaimed")
    } else {
        t.expect(false, "round trip: reclaimed")
    }
    t.expect(!fm.fileExists(atPath: victim.path), "round trip: bytes actually freed")

    let recovered = try? RestoreEngine(manifest: rtStore).plan(for: victim.path)
    t.equal((recovered ?? nil)?.command, "npm ci", "round trip: restore command recovered from manifest")
}
