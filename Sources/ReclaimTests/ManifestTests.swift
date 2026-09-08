import Foundation
import ReclaimCore

@MainActor func runManifestTests(_ t: Harness) {
    t.section("Manifest")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("reclaim-manifest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ManifestStore(url: dir.appendingPathComponent("manifest.jsonl"))

    t.equal((try? store.all().count) ?? -1, 0, "empty store reads as empty, not an error")

    let e1 = ManifestEntry(artefactID: "ollama.models", path: "/fixture/models",
                           tier: .exact, bytesFreed: 14_000_000_000,
                           recipe: Recipe(kind: .ollamaPull, command: "ollama pull llama3:8b"),
                           timestamp: Date(timeIntervalSince1970: 1000), snapshotName: nil)
    let e2 = ManifestEntry(artefactID: "npm.cache", path: "/fixture/npm",
                           tier: .exact, bytesFreed: 4_200_000_000,
                           recipe: Recipe(kind: .npmCleanInstall, command: "npm ci"),
                           timestamp: Date(timeIntervalSince1970: 2000), snapshotName: nil)

    try? store.append(e1)
    try? store.append(e2)

    guard let all = try? store.all() else {
        t.expect(false, "store reads back")
        return
    }
    t.equal(all.count, 2, "both entries persisted")
    t.equal(all[0].artefactID, "ollama.models", "append order preserved")
    t.equal(all[1].bytesFreed, 4_200_000_000, "bytes freed round-trip")
    t.equal(all[0].recipe.command, "ollama pull llama3:8b", "restore command round-trips verbatim")

    // A second store over the same file must see prior entries — append-only, not truncating.
    let reopened = ManifestStore(url: dir.appendingPathComponent("manifest.jsonl"))
    t.equal((try? reopened.all().count) ?? -1, 2, "reopening does not truncate")

    // A corrupt line must not destroy the whole log.
    let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent("manifest.jsonl"))
    try? handle?.seekToEnd()
    try? handle?.write(contentsOf: Data("{not json\n".utf8))
    try? handle?.close()
    t.equal((try? reopened.all().count) ?? -1, 2, "corrupt line is skipped, valid entries survive")
}
