import Foundation

public enum Survey {
    /// Explicit paths *restrict* the run; they never extend it. Passing a path
    /// means "this and nothing else". The inverse — unioning explicit paths with
    /// the full catalogue — is how `reclaim --confirm /tmp/fixture` came to
    /// action every catalogued path on a real machine.
    public static func targets(catalogue: Catalogue, explicitPaths: [String]) -> [String] {
        guard explicitPaths.isEmpty else {
            return explicitPaths.map { ($0 as NSString).expandingTildeInPath }
        }
        return catalogue.entries.map(\.expandedPath)
    }
}
