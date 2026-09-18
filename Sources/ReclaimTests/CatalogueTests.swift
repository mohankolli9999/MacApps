import Foundation
import ReclaimCore

@MainActor func runCatalogueTests(_ t: Harness) {
    t.section("Catalogue")

    let json = """
    {
      "version": 1,
      "entries": [
        { "id": "ollama.models", "displayName": "Ollama models",
          "path": "~/.ollama/models", "tier": "exact",
          "recipeKind": "ollamaPull", "validator": "ollama" },
        { "id": "docker.volumes", "displayName": "Docker named volumes",
          "path": "~/Library/Containers/com.docker.docker/Data/vms",
          "tier": "irreplaceable", "validator": "none" }
      ]
    }
    """.data(using: .utf8)!

    guard let cat = try? Catalogue.load(from: json) else {
        t.expect(false, "catalogue parses")
        return
    }
    t.equal(cat.entries.count, 2, "loads all entries")
    t.equal(cat.entries[0].tier, .exact, "parses tier")
    t.equal(cat.entries[0].recipeKind, .ollamaPull, "parses recipe kind")
    t.expect(cat.entries[1].recipeKind == nil, "irreplaceable entry has no recipe kind")
    t.expect(cat.entries[0].expandedPath.hasPrefix(NSHomeDirectory()), "expands tilde")
    t.expect(!cat.entries[0].expandedPath.contains("~"), "no tilde remains after expansion")

    t.expect(cat.entry(id: "ollama.models") != nil, "lookup by id finds entry")
    t.expect(cat.entry(id: "nope") == nil, "lookup by unknown id returns nil")

    // The shipped catalogue must be valid and cover the measured categories.
    guard let bundled = try? Catalogue.bundled() else {
        t.expect(false, "bundled catalogue loads")
        return
    }
    for required in ["ollama.models", "huggingface.hub", "npm.cache", "xcode.deriveddata", "docker.volumes"] {
        t.expect(bundled.entry(id: required) != nil, "bundled catalogue has \(required)")
    }
    t.equal(bundled.entry(id: "docker.volumes")?.tier, .irreplaceable, "docker volumes are irreplaceable")
    t.equal(bundled.entry(id: "xcode.deriveddata")?.tier, .costly, "DerivedData is costly, not exact")
}
