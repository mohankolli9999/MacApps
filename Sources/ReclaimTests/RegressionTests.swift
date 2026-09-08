import Foundation
import ReclaimCore

/// Regressions from the 2026-09-09 incident, in which `scripts/acceptance.sh`
/// deleted ~37GB of real caches. Each test here corresponds to one defect that
/// contributed to it.
@MainActor func runRegressionTests(_ t: Harness) {
    t.section("Regression: explicit paths scope the run")

    let json = """
    {"version":1,"entries":[
      {"id":"npm.cache","displayName":"npm","path":"/fixture/npm","tier":"exact",
       "recipeKind":"npmCleanInstall","validator":"alwaysProven"},
      {"id":"pip.cache","displayName":"pip","path":"/fixture/pip","tier":"exact",
       "recipeKind":"pipDownload","validator":"alwaysProven"}
    ]}
    """.data(using: .utf8)!
    let cat = try! Catalogue.load(from: json)

    // With no explicit paths, the whole catalogue is in scope.
    t.equal(Survey.targets(catalogue: cat, explicitPaths: []).count, 2,
            "no explicit paths surveys the whole catalogue")

    // With explicit paths, ONLY those paths are in scope. The original bug was
    // that explicit paths were appended to the catalogue sweep instead.
    let scoped = Survey.targets(catalogue: cat, explicitPaths: ["/fixture/npm"])
    t.equal(scoped.count, 1, "explicit path narrows the survey to one target")
    t.equal(scoped.first, "/fixture/npm", "explicit path is the only target")
    t.expect(!scoped.contains("/fixture/pip"), "explicit path excludes other catalogue entries")

    t.section("Regression: placeholder recipes are not proof")

    let artefact = Artefact(id: "ollama.models", path: URL(fileURLWithPath: "/fixture/models"),
                            logicalBytes: 1, physicalBytes: 1, tier: .exact)

    // The incident deleted 15GB of Ollama models recording only
    // "ollama pull <model>" — a command that restores nothing.
    let placeholder = Recipe(kind: .ollamaPull, command: "ollama pull <model>")
    t.expect(!placeholder.isConcrete, "a command containing <placeholders> is not concrete")

    let downgraded = applyValidation(artefact, .proven(placeholder))
    t.equal(downgraded.tier, .irreplaceable,
            "a placeholder recipe downgrades even when the validator said proven")
    t.expect(downgraded.recipe == nil, "a placeholder recipe is not attached")

    let concrete = Recipe(kind: .ollamaPull, command: "ollama pull deepseek-r1:8b")
    t.expect(concrete.isConcrete, "a fully resolved command is concrete")
    let kept = applyValidation(artefact, .proven(concrete))
    t.equal(kept.tier, .exact, "a concrete recipe keeps the tier")
    t.expect(kept.recipe != nil, "a concrete recipe is attached")

    t.section("Regression: executor refuses placeholder recipes")

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("reclaim-regress-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let victim = dir.appendingPathComponent("victim")
    try? fm.createDirectory(at: victim, withIntermediateDirectories: true)
    try? Data(repeating: 0x41, count: 512).write(to: victim.appendingPathComponent("f"))

    let store = ManifestStore(url: dir.appendingPathComponent("m.jsonl"))
    let withPlaceholder = Artefact(id: "ollama.models", path: victim,
                                   logicalBytes: 512, physicalBytes: 4096,
                                   tier: .exact, recipe: placeholder)
    let out = (try? ReclaimExecutor(manifest: store, mode: .reclaim).execute([withPlaceholder])) ?? []
    if case .skipped = out.first?.1 {
        t.expect(true, "executor skips an artefact carrying a placeholder recipe")
    } else {
        t.expect(false, "executor skips an artefact carrying a placeholder recipe")
    }
    t.expect(fm.fileExists(atPath: victim.path), "artefact with a placeholder recipe survives")
}
