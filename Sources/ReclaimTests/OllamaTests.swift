import Foundation
import ReclaimCore

private func writeManifest(_ root: URL, _ path: String, layerSizes: [Int64], configSize: Int64 = 512) {
    let url = root.appendingPathComponent("manifests/\(path)")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let layers = layerSizes.map {
        #"{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:aa","size":\#($0)}"#
    }.joined(separator: ",")
    let json = """
    {"schemaVersion":2,
     "config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:bb","size":\(configSize)},
     "layers":[\(layers)]}
    """
    try? json.data(using: .utf8)!.write(to: url)
}

@MainActor func runOllamaTests(_ t: Harness) {
    t.section("Ollama model extraction")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ollama-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    t.expect(OllamaExtractor.models(root: root).isEmpty, "a missing root yields no models")

    writeManifest(root, "registry.ollama.ai/library/llama3.2/3b", layerSizes: [2_000_000_000, 1_000])
    writeManifest(root, "registry.ollama.ai/library/codellama/7b-instruct", layerSizes: [3_800_000_000])
    writeManifest(root, "registry.ollama.ai/myuser/custom/latest", layerSizes: [1_000])

    // A partially written manifest must not take the rest of the list down.
    let broken = root.appendingPathComponent("manifests/registry.ollama.ai/library/broken/tag")
    try? fm.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("{not json".utf8).write(to: broken)

    // Finder litter sits alongside real manifests and must be ignored.
    try? Data().write(to: root.appendingPathComponent("manifests/registry.ollama.ai/library/.DS_Store"))

    let models = OllamaExtractor.models(root: root)
    let refs = models.map(\.reference)

    t.equal(models.count, 3, "three readable manifests found")
    t.expect(refs.contains("llama3.2:3b"), "library models drop the namespace")
    t.expect(refs.contains("codellama:7b-instruct"), "tags with hyphens survive")
    t.expect(refs.contains("myuser/custom:latest"), "non-library models keep their namespace")
    t.expect(!refs.contains(where: { $0.contains("broken") }), "corrupt manifest is skipped")
    t.expect(!refs.contains(where: { $0.contains("DS_Store") }), "dotfiles are skipped")

    if let llama = models.first(where: { $0.reference == "llama3.2:3b" }) {
        t.equal(llama.bytes, 2_000_001_512, "size sums layers and config")
    }
    t.expect(models.map(\.bytes) == models.map(\.bytes).sorted(by: >),
             "models are ordered largest first")

    t.section("Ollama recipe")

    guard let recipe = OllamaExtractor.recipe(root: root) else {
        t.expect(false, "a populated root produces a recipe")
        return
    }
    t.equal(recipe.kind, .ollamaPull, "recipe is an ollama pull")
    t.expect(recipe.isConcrete, "extracted recipe carries no placeholders")
    t.expect(recipe.command.contains("ollama pull llama3.2:3b"), "recipe names the actual model")
    t.expect(recipe.command.contains("ollama pull myuser/custom:latest"), "recipe covers every model")
    t.equal(recipe.command.split(separator: "\n").count, 3, "one pull command per model")
    t.equal(recipe.cost.bytesToRefetch, 3_800_000_512 + 2_000_001_512 + 1_512,
            "refetch cost is the total of all models")
    t.equal(recipe.parameters["models"], "codellama:7b-instruct,llama3.2:3b,myuser/custom:latest",
            "models are recorded individually for the manifest")

    // The whole point: this must survive a round trip through the manifest,
    // because after deletion the manifest is the only surviving record.
    let entry = ManifestEntry(artefactID: "ollama.models", path: root.path,
                              tier: .exact, bytesFreed: 1, recipe: recipe)
    let decoded = try? JSONDecoder().decode(ManifestEntry.self, from: JSONEncoder().encode(entry))
    t.expect(decoded?.recipe.command.contains("llama3.2:3b") == true,
             "model names survive a manifest round trip")

    t.expect(OllamaExtractor.recipe(root: fm.temporaryDirectory
        .appendingPathComponent("nope-\(UUID().uuidString)")) == nil,
             "an empty root produces no recipe rather than a template")
}
