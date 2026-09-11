import Foundation
import ReclaimCore

@MainActor func runAll() async -> Int32 {
    let t = Harness()

    t.section("Tier ordering")
    t.expect(Tier.exact < Tier.costly, "exact sorts before costly")
    t.expect(Tier.costly < Tier.irreplaceable, "costly sorts before irreplaceable")
    t.expect(Tier.irreplaceable < Tier.unknown, "irreplaceable sorts before unknown")
    t.expect(Tier.exact <= .costly, "action ceiling admits exact and costly")
    t.expect(!(Tier.irreplaceable <= .costly), "action ceiling excludes irreplaceable")

    t.section("Recipe")
    let r = Recipe(kind: .ollamaPull,
                   command: "ollama pull llama3:8b",
                   parameters: ["digest": "sha256:abc"],
                   cost: Cost(seconds: nil, bytesToRefetch: 4_700_000_000))
    t.equal(r.kind, .ollamaPull, "recipe kind round-trips")
    t.equal(r.parameters["digest"], "sha256:abc", "recipe parameters retained")

    // isConcrete only rules out unresolved placeholders. Prose passes it, and
    // prose on a clipboard is useless, so the two questions are not the same.
    t.expect(Recipe(kind: .npmCleanInstall, command: "npm ci").isRunnableCommand,
             "a resolved command is runnable")
    t.expect(!Recipe(kind: .ollamaPull, command: "ollama pull <model>").isRunnableCommand,
             "a template is not runnable")
    t.expect(!Recipe(kind: .rebuild, command: "rebuild the project").isRunnableCommand,
             "prose describing a rebuild is not a command to run")
    t.expect(!Recipe(kind: .automatic, command: "the tool refetches this on next use").isRunnableCommand,
             "an automatic refetch has nothing to run")

    // A trashed file has a real way back, so it counts as recorded — but Put Back
    // is a gesture in Finder, not a command anyone can paste into a shell.
    let trashed = Recipe(kind: .trash, command: "In Finder, open the Trash and choose Put Back")
    t.expect(trashed.isConcrete, "a trashed file did record a way back")
    t.expect(!trashed.isRunnableCommand, "Put Back is a gesture, not a command to run")

    t.section("Artefact")
    let a = Artefact(id: "ollama.models",
                     path: URL(fileURLWithPath: "/tmp/x"),
                     logicalBytes: 100,
                     reclaimableBytes: 90,
                     tier: .exact,
                     recipe: r)
    t.equal(a.tier, .exact, "artefact carries tier")
    t.expect(a.recipe != nil, "artefact carries recipe")

    runScannerTests(t)
    runCatalogueTests(t)
    runClassifierTests(t)
    runValidatorTests(t)
    runManifestTests(t)
    runExecutorTests(t)
    runRestoreTests(t)
    runRegressionTests(t)
    runTreemapTests(t)
    runOllamaTests(t)
    runStreamingScanTests(t)
    runVolumeScanTests(t)
    runStorageSafetyTests(t)
    runFileSpaceTests(t)
    runSelectionSpaceTests(t)
    runCollectorTests(t)
    runVolumeLedgerTests(t)
    runVolumeSpaceTests(t)
    runByteFormatTests(t)
    runAccessProbeTests(t)
    runLicenseTests(t)
    runEntitlementTests(t)
    await runAsyncValidatorTests(t)
    await runConcurrentScanTests(t)
    await runOffVolumeTests(t)
    runFirmlinkTests(t)
    runSymlinkCrossingTests(t)
    runNoCloneSupportTests(t)
    await runCloudPlaceholderTests(t)

    return t.report()
}

@main
struct TestRunner {
    static func main() async {
        exit(await runAll())
    }
}
