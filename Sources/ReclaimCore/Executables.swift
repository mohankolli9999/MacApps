import Foundation

public enum Executables {
    /// Locate a tool the way a shell would, plus the usual package-manager bins.
    ///
    /// An app launched from Finder inherits a minimal PATH — typically just
    /// /usr/bin:/bin:/usr/sbin:/sbin — so Homebrew tools are invisible to a GUI
    /// build even though they work fine in Terminal. Hardcoding a single path is
    /// worse still: /usr/local/bin/ollama is a symlink into Ollama.app on some
    /// machines and absent on others, while the real binary is in /opt/homebrew.
    public static func find(_ name: String) -> String? {
        let fromPath = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        for directory in fromPath + fallbacks {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
