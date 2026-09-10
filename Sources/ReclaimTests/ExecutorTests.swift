import Foundation
import ReclaimCore

@MainActor func runExecutorTests(_ t: Harness) {
    t.section("Executor")

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("reclaim-exec-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    func makeVictim(_ name: String) -> URL {
        let p = dir.appendingPathComponent(name)
        try? fm.createDirectory(at: p, withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: 1024).write(to: p.appendingPathComponent("f.bin"))
        return p
    }

    let recipe = Recipe(kind: .npmCleanInstall, command: "npm ci")

    // Dry run must not delete anything.
    let v1 = makeVictim("dryrun")
    let dryStore = ManifestStore(url: dir.appendingPathComponent("dry.jsonl"))
    let dry = ReclaimExecutor(manifest: dryStore, mode: .dryRun)
    let a1 = Artefact(id: "npm.cache", path: v1, logicalBytes: 1024, reclaimableBytes: 4096,
                      tier: .exact, recipe: recipe)
    let dryResults = (try? dry.execute([a1])) ?? []
    t.equal(dryResults.count, 1, "dry run reports one result")
    if case .wouldReclaim(let bytes) = dryResults.first?.1 {
        t.equal(bytes, 4096, "dry run reports physical bytes")
    } else {
        t.expect(false, "dry run yields wouldReclaim")
    }
    t.expect(fm.fileExists(atPath: v1.path), "dry run leaves the directory intact")
    t.equal((try? dryStore.all().count) ?? -1, 0, "dry run writes no manifest entry")

    // Reclaim must delete and record.
    let v2 = makeVictim("live")
    let liveStore = ManifestStore(url: dir.appendingPathComponent("live.jsonl"))
    let live = ReclaimExecutor(manifest: liveStore, mode: .reclaim)
    let a2 = Artefact(id: "npm.cache", path: v2, logicalBytes: 1024, reclaimableBytes: 4096,
                      tier: .exact, recipe: recipe)
    let liveResults = (try? live.execute([a2])) ?? []
    if case .reclaimed(let bytes) = liveResults.first?.1 {
        t.equal(bytes, 4096, "reclaim reports physical bytes")
    } else {
        t.expect(false, "reclaim yields reclaimed")
    }
    t.expect(!fm.fileExists(atPath: v2.path), "reclaim removes the directory")
    t.equal((try? liveStore.all().count) ?? -1, 1, "reclaim records one manifest entry")
    t.equal((try? liveStore.all())?.first?.recipe.command, "npm ci", "manifest stores the restore command")

    // The manifest is what the History tab adds up, so it has to record what the
    // volume actually got back rather than what the folder occupied.
    let vShared = makeVictim("shared")
    let sharedStore = ManifestStore(url: dir.appendingPathComponent("shared.jsonl"))
    let shared = ReclaimExecutor(manifest: sharedStore, mode: .reclaim)
    let a4 = Artefact(id: "npm.cache", path: vShared, logicalBytes: 4096,
                      reclaimableBytes: 1024, tier: .exact, recipe: recipe)
    let sharedResults = (try? shared.execute([a4])) ?? []
    if case .reclaimed(let bytes) = sharedResults.first?.1 {
        t.equal(bytes, 1024, "reclaim promises what deleting frees")
    } else {
        t.expect(false, "reclaim yields reclaimed")
    }
    t.equal((try? sharedStore.all())?.first?.bytesFreed, 1024,
            "and the manifest records the same figure")

    // The guarantee: no recipe means no deletion, whatever the tier claims.
    let v3 = makeVictim("norecipe")
    let g1 = Artefact(id: "npm.cache", path: v3, logicalBytes: 1024, reclaimableBytes: 4096,
                      tier: .exact, recipe: nil)
    let r3 = (try? live.execute([g1])) ?? []
    if case .skipped(let reason) = r3.first?.1 {
        t.expect(reason.contains("recipe"), "skip reason names the missing recipe")
    } else {
        t.expect(false, "artefact without a recipe is skipped")
    }
    t.expect(fm.fileExists(atPath: v3.path), "artefact without a recipe survives")

    // Irreplaceable is never actioned, even holding a recipe.
    let v4 = makeVictim("irreplaceable")
    let g2 = Artefact(id: "docker.volumes", path: v4, logicalBytes: 1024, reclaimableBytes: 4096,
                      tier: .irreplaceable, recipe: recipe)
    let r4 = (try? live.execute([g2])) ?? []
    if case .skipped = r4.first?.1 {
        t.expect(true, "irreplaceable artefact is skipped")
    } else {
        t.expect(false, "irreplaceable artefact is skipped")
    }
    t.expect(fm.fileExists(atPath: v4.path), "irreplaceable artefact survives")

    // The ordering guarantee. If the restore record cannot be written, the bytes
    // must still be on disk: deleting first and recording second turns a failed
    // write into the one loss this product exists to prevent.
    let blocked = dir.appendingPathComponent("blocked")
    try? Data("this is a file, not a directory".utf8).write(to: blocked)
    let v6 = makeVictim("unrecorded")
    let brokenStore = ManifestStore(url: blocked.appendingPathComponent("manifest.jsonl"))
    let broken = ReclaimExecutor(manifest: brokenStore, mode: .reclaim)
    let a6 = Artefact(id: "npm.cache", path: v6, logicalBytes: 1024, reclaimableBytes: 4096,
                      tier: .exact, recipe: recipe)
    var recordFailed = false
    do { _ = try broken.execute([a6]) } catch { recordFailed = true }
    t.expect(recordFailed, "an unwritable manifest surfaces as an error")
    t.expect(fm.fileExists(atPath: v6.path), "an unwritable manifest leaves the bytes on disk")

    // Unknown is never actioned.
    let v5 = makeVictim("unknown")
    let g3 = Artefact(id: "unknown", path: v5, logicalBytes: 1024, reclaimableBytes: 4096,
                      tier: .unknown, recipe: nil)
    _ = try? live.execute([g3])
    t.expect(fm.fileExists(atPath: v5.path), "unknown artefact survives")
}
