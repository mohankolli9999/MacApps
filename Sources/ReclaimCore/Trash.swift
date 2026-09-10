import Foundation

/// Removal for files the app cannot prove how to rebuild.
///
/// A catalogued cache is deleted outright because its restore recipe is the way
/// back. Anything else the user picks off the storage map has no recipe, so the
/// Trash becomes the way back — the same guarantee, delegated to the system's
/// own undo rather than abandoned.
public enum Trash {
    @discardableResult
    public static func put(_ url: URL) throws -> URL {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        // trashItem only reports nil here when it did not move anything, which it
        // signals by throwing first; the cast keeps the caller's contract simple.
        return landed as URL? ?? url
    }
}

/// What removing something off the storage map actually costs.
///
/// The tier system answers "can this be rebuilt", which only a catalogued
/// artefact can be asked. An arbitrary file has no recipe, so the question
/// becomes "what breaks if this goes" — a different axis with its own scale.
public enum StorageRisk: String, Sendable, Equatable {
    /// Derived bytes. The tool that made them will make them again.
    case safe
    /// Your own files. Nothing breaks, and nothing brings them back either.
    case yours
    /// Something an app is using. Removing it may break that app.
    case risky
    /// Not the app's to remove.
    case blocked

    public var isTrashable: Bool { self != .blocked }
}

public enum StorageSafety {
    private static let cacheComponents: Set<String> = [
        "Caches", "CachedData", "DerivedData", "node_modules", ".cache", "_cacache",
    ]

    private static let yourFolders: Set<String> = [
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
    ]

    /// Folders macOS creates and depends on. Their contents are fair game; the
    /// folders themselves carry system meaning, and nobody opens a disk map
    /// intending to remove one.
    private static let homeFixtures: Set<String> = yourFolders.union([
        "Library", "Applications", "Public", ".Trash",
    ])

    /// Deliberately a hard gate, not a warning. Everywhere else on the map the
    /// user decides and the Trash is the way back — but the Trash is only a way
    /// back for things the user owns, and outside these roots macOS will either
    /// refuse the move or let it break something no undo can reach.
    public static func risk(for url: URL) -> StorageRisk {
        let components = url.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let inHome = path.hasPrefix(home + "/")

        guard inHome || path.hasPrefix("/Applications/") || path.hasPrefix("/Volumes/") else {
            return .blocked
        }

        let homeDepth = URL(fileURLWithPath: home).pathComponents.count
        if inHome, components.count == homeDepth + 1, homeFixtures.contains(components.last!) {
            return .blocked
        }
        // /Volumes/<disk> is a mount point rather than an item on it.
        if path.hasPrefix("/Volumes/"), components.count <= 3 { return .blocked }

        if components.contains(where: cacheComponents.contains) { return .safe }
        if inHome, yourFolders.contains(components[homeDepth]) { return .yours }
        return .risky
    }
}

/// Whether the app can see the whole disk.
///
/// macOS deliberately offers no API to query or request Full Disk Access — an
/// app cannot raise the permission sheet itself. Reading something TCC protects
/// and seeing whether it is refused is the only signal available, and sending
/// the user to the right Settings pane is the only action available.
public enum FullDiskAccess {
    public enum Access: Sendable, Equatable {
        case granted
        case denied
        /// Nothing probed was there to answer with. A Mac that has never opened
        /// Mail looks exactly like one refusing to show it, and telling someone
        /// to grant a permission they already hold is worse than saying nothing.
        case unknown
    }

    /// Locations TCC guards for every app regardless of entitlements. The TCC
    /// directory leads because it is the one that exists on every Mac, so its
    /// refusal is a refusal rather than an absence.
    private static let protectedPaths = [
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC",
        NSHomeDirectory() + "/Library/Safari",
        NSHomeDirectory() + "/Library/Mail",
    ]

    public static var access: Access { check(paths: protectedPaths) }
    public static var isGranted: Bool { access == .granted }

    public static func check(paths: [String]) -> Access {
        var refused = false
        for path in paths {
            do {
                _ = try FileSpace.contents(of: path)
                return .granted
            } catch FileSpace.ListingError.denied {
                refused = true
            } catch {
                continue
            }
        }
        return refused ? .denied : .unknown
    }

    /// Deep link to Settings › Privacy & Security › Full Disk Access.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!
}
