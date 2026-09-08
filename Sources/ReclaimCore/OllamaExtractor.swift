import Foundation

public struct OllamaModel: Sendable, Equatable {
    public var reference: String
    public var bytes: Int64
}

/// Reads `~/.ollama/models/manifests` and turns it into concrete pull commands.
///
/// This is what "restore recipes, not retained bytes" actually requires. A
/// recipe of `ollama pull <model>` is worthless once the models are gone: the
/// identifiers died with them. The manifest tree is the only place the names
/// live, so they must be captured *before* deletion, not reconstructed after.
public enum OllamaExtractor {
    private struct Manifest: Decodable {
        struct Layer: Decodable { let size: Int64 }
        let config: Layer?
        let layers: [Layer]?
    }

    public static func models(root: URL) -> [OllamaModel] {
        let manifests = root.appendingPathComponent("manifests")
        guard let walker = FileManager.default.enumerator(
            at: manifests,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [OllamaModel] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  let reference = reference(for: url, under: manifests)
            else { continue }

            let bytes = (manifest.layers ?? []).reduce(0) { $0 + $1.size } + (manifest.config?.size ?? 0)
            out.append(OllamaModel(reference: reference, bytes: bytes))
        }
        return out.sorted { $0.bytes == $1.bytes ? $0.reference < $1.reference : $0.bytes > $1.bytes }
    }

    public static func recipe(root: URL) -> Recipe? {
        let found = models(root: root)
        guard !found.isEmpty else { return nil }

        let references = found.map(\.reference).sorted()
        return Recipe(
            kind: .ollamaPull,
            command: references.map { "ollama pull \($0)" }.joined(separator: "\n"),
            parameters: ["models": references.joined(separator: ","),
                         "count": String(found.count)],
            cost: Cost(bytesToRefetch: found.reduce(0) { $0 + $1.bytes })
        )
    }

    /// `<registry>/<namespace>/<model>/<tag>` becomes `namespace/model:tag`,
    /// with the `library` namespace elided the way `ollama pull` expects.
    private static func reference(for url: URL, under manifests: URL) -> String? {
        let base = manifests.standardizedFileURL.pathComponents
        let full = url.standardizedFileURL.pathComponents
        guard full.count == base.count + 4 else { return nil }

        let namespace = full[base.count + 1]
        let model = full[base.count + 2]
        let tag = full[base.count + 3]
        return namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
    }
}
