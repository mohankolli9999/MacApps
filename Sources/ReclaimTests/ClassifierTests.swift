import Foundation
import ReclaimCore

@MainActor func runClassifierTests(_ t: Harness) {
    t.section("Classifier")

    let json = """
    {
      "version": 1,
      "entries": [
        { "id": "npm.cache", "displayName": "npm cache", "path": "/fixture/.npm/_cacache",
          "tier": "exact", "recipeKind": "npmCleanInstall", "validator": "alwaysProven" }
      ]
    }
    """.data(using: .utf8)!
    let cat = try! Catalogue.load(from: json)
    let c = Classifier(catalogue: cat)
    let m = DiskScanner.Measurement(logicalBytes: 500, reclaimableBytes: 512, fileCount: 3)

    let known = c.classify(path: URL(fileURLWithPath: "/fixture/.npm/_cacache"), measurement: m)
    t.equal(known.id, "npm.cache", "known path maps to catalogue id")
    t.equal(known.tier, .exact, "known path takes catalogue tier")
    t.equal(known.logicalBytes, 500, "measurement carried through")

    let stranger = c.classify(path: URL(fileURLWithPath: "/fixture/my-thesis"), measurement: m)
    t.equal(stranger.tier, .unknown, "unrecognised path is unknown, never actionable")
    t.expect(stranger.recipe == nil, "unknown artefact has no recipe")
    t.expect(!(stranger.tier <= Tier.automaticCeiling), "unknown is above the automatic ceiling")

    // A path *inside* a catalogued directory belongs to that entry.
    let child = c.classify(path: URL(fileURLWithPath: "/fixture/.npm/_cacache/index-v5"), measurement: m)
    t.equal(child.id, "npm.cache", "descendant path inherits the catalogue entry")

    // A path that merely shares a prefix string must not match.
    let impostor = c.classify(path: URL(fileURLWithPath: "/fixture/.npm/_cacache-backup"), measurement: m)
    t.equal(impostor.tier, .unknown, "sibling with shared prefix does not match")

    // A measurement carries two very different sizes and the artefact takes one
    // of them. The reclaim button and the manifest both quote whichever it took,
    // so a cache holding cloned blocks — claiming 4096, returning 1024 — is the
    // fixture that catches the wrong one being wired through.
    let shared = DiskScanner.Measurement(logicalBytes: 4096, reclaimableBytes: 1024, fileCount: 1)
    let cloned = c.classify(path: URL(fileURLWithPath: "/fixture/.npm/_cacache"), measurement: shared)
    t.equal(cloned.reclaimableBytes, 1024, "artefact carries what deleting frees, not what it claims")
}
