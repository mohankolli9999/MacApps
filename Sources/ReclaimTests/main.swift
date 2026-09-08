import Foundation
import ReclaimCore

@MainActor func runAll() -> Int32 {
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

    t.section("Artefact")
    let a = Artefact(id: "ollama.models",
                     path: URL(fileURLWithPath: "/tmp/x"),
                     logicalBytes: 100,
                     physicalBytes: 90,
                     tier: .exact,
                     recipe: r)
    t.equal(a.tier, .exact, "artefact carries tier")
    t.expect(a.recipe != nil, "artefact carries recipe")

    return t.report()
}

exit(MainActor.assumeIsolated { runAll() })
