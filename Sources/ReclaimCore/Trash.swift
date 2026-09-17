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

/// One of Chromium's on-disk caches.
///
/// Every Electron app embeds Chromium, so these directory names turn up under
/// apps nobody thinks of as browsers — a note-taker, an API client, a chat
/// client, an antivirus agent. Most of them sit in Application Support rather
/// than Caches, so neither the folder above them nor the app that owns them
/// marks them as disposable, and a disk map shows them as ordinary app data.
/// Recognising the names is the only thing that finds them.
public struct BrowserCache: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Refetched or recompiled on demand. Nothing is lost with it.
        case derived
        /// Service worker storage. Chromium lets a site keep pages for offline
        /// reading and writes queued for a network that has not come back in
        /// here, so it is not derived data and the user has to decide.
        case offline
    }

    /// Chromium's own names, which is why they read like code rather than like
    /// anything a person would recognise on a disk map. The label beside each
    /// is what the review list shows instead.
    private static let names: [String: (kind: Kind, contents: String)] = [
        "Cache_Data": (.derived, "web cache"),
        "Code Cache": (.derived, "compiled scripts"),
        "GPUCache": (.derived, "graphics cache"),
        "ShaderCache": (.derived, "graphics cache"),
        "DawnCache": (.derived, "graphics cache"),
        "DawnGraphiteCache": (.derived, "graphics cache"),
        "DawnWebGPUCache": (.derived, "graphics cache"),
        "component_crx_cache": (.derived, "downloaded components"),
        "CacheStorage": (.offline, "offline storage"),
    ]

    /// The folders an app's own data hangs off. The last one on the path wins:
    /// a sandboxed app has a second Library inside its container, and the name
    /// in there is the app rather than the container's bundle identifier.
    private static let anchors: Set<String> = ["Caches", "Application Support"]

    public let kind: Kind
    /// The app this belongs to, named the way its owner would name it.
    public let owner: String
    /// What the directory holds, in the user's words rather than Chromium's.
    public let contents: String

    public static func match(_ url: URL) -> BrowserCache? {
        let components = url.standardizedFileURL.pathComponents
        guard let last = components.last, let known = names[last] else { return nil }
        // Every one of these is app-internal. A folder of the user's that
        // happens to be called Code Cache is their work, and offering to delete
        // it would be the one mistake this screen cannot afford.
        guard let anchor = components.lastIndex(where: anchors.contains),
              anchor + 1 < components.count
        else { return nil }
        return BrowserCache(kind: known.kind,
                            owner: appName(components[anchor + 1]),
                            contents: known.contents)
    }

    /// A bundle identifier is a path segment, not a label. Its last part is the
    /// name the app actually ships under.
    private static func appName(_ component: String) -> String {
        guard !component.contains(" "), component.contains("."),
              let tail = component.split(separator: ".").last
        else { return component }
        return String(tail)
    }
}

/// The browser caches on a disk, read off the tree the scan already built.
///
/// By the time this runs the whole volume is in memory, so the caches cost one
/// traversal of it and no disk at all — which is the only reason the app can
/// offer them the moment the map appears rather than after a second walk.
public struct CacheSurvey: Sendable, Equatable {
    public struct Finding: Sendable, Equatable, Identifiable {
        public let node: StorageNode
        public let cache: BrowserCache
        public var id: String { node.id }
    }

    /// Largest first, which is the order worth reviewing: on a real disk the
    /// first ten rows hold most of the bytes and the rest is a scroll.
    public let findings: [Finding]

    public init(of root: StorageNode) {
        var found: [Finding] = []
        func walk(_ node: StorageNode) {
            if let cache = BrowserCache.match(node.url) {
                // Taken whole. Anything below is going with it, so listing that
                // too would double the total and put a row on screen that
                // disappears under the user when they tick the one above it.
                found.append(Finding(node: node, cache: cache))
                return
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        findings = found.sorted { $0.node.physicalBytes > $1.node.physicalBytes }
    }

    public var derived: [Finding] { findings.filter { $0.cache.kind == .derived } }
    public var offline: [Finding] { findings.filter { $0.cache.kind == .offline } }

    /// A floor, like every other total the app quotes before a selection is
    /// made: caches that are clones of each other free more together than the
    /// sum says, and only `SelectionSpace` can work that out.
    public var floorBytes: Int64 { Self.floor(findings) }
    public var derivedFloorBytes: Int64 { Self.floor(derived) }
    public var offlineFloorBytes: Int64 { Self.floor(offline) }

    private static func floor(_ items: [Finding]) -> Int64 {
        items.reduce(0) { $0 + $1.node.reclaimableBytes }
    }
}

/// Whether handing a path to Quick Look costs anything but a redraw.
public enum PreviewVerdict: Sendable, Equatable {
    case allowed
    /// Nothing is on this disk, so previewing fetches the lot. The figure is the
    /// file's claimed size, which is the number the user is about to spend.
    case wouldDownload(bytes: Int64)
    case missing
}

public enum StorageSafety {
    /// `FileSpace.refuseToMaterialisePlaceholders()` does not cover this, and the
    /// reason is worth knowing before anyone deletes the check as redundant: that
    /// policy is `IOPOL_SCOPE_PROCESS`, it reaches descendants only by inheritance
    /// across fork, and the Quick Look agents that draw a preview are launchd jobs
    /// parented to PID 1 — so there is no inheritance edge to carry it, and their
    /// ambient setting is materialisation actively on. The scan is protected; the
    /// preview is not, and nothing this process can call would change that. So a
    /// cloud row that costs nothing to *measure* costs its whole size to *look
    /// at*, which is the one surprise a tool for freeing space must not spring.
    public static func preview(for url: URL) -> PreviewVerdict {
        var info = stat()
        guard lstat(url.standardizedFileURL.path, &info) == 0 else { return .missing }
        return preview(flags: info.st_flags, logicalBytes: Int64(info.st_size))
    }

    /// Split from the syscall above because `SF_DATALESS` needs root to set, so no
    /// fixture can be a real placeholder and the decision would otherwise only be
    /// exercised on a machine that happens to have a cloud provider signed in.
    public static func preview(flags: UInt32, logicalBytes: Int64) -> PreviewVerdict {
        flags & UInt32(SF_DATALESS) != 0 ? .wouldDownload(bytes: logicalBytes) : .allowed
    }

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

        // System Integrity Protection lives inside the allowlist: /Applications
        // holds Apple's own bundles, and the kernel refuses to move them however
        // much access the user has granted. Asking the filesystem rather than
        // testing the path on purpose — a prefix list is the thing that put this
        // bug here, and the flag is what the kernel itself consults. A vanished
        // file falls through to the ordinary rules, which give it an answer the
        // user can act on instead of an explanation that would be wrong.
        if isRestricted(path) { return .blocked }

        let homeDepth = URL(fileURLWithPath: home).pathComponents.count
        if inHome, components.count == homeDepth + 1, homeFixtures.contains(components.last!) {
            return .blocked
        }
        // /Volumes/<disk> is a mount point rather than an item on it.
        if path.hasPrefix("/Volumes/"), components.count <= 3 { return .blocked }

        // Ahead of the folder test, so the same kind of directory gets the same
        // answer wherever its app keeps it — and so service worker storage is
        // not waved through as safe merely for sitting under a Caches folder.
        if let cache = BrowserCache.match(url) {
            return cache.kind == .derived ? .safe : .risky
        }
        if components.contains(where: cacheComponents.contains) { return .safe }
        if inHome, yourFolders.contains(components[homeDepth]) { return .yours }
        return .risky
    }

    /// Restriction is carried by a bundle's contents as well as the bundle, so
    /// one test on the node's own path covers a user who opened Safari.app and
    /// ticked a framework inside it.
    ///
    /// This runs while rows are being drawn rather than during the scan, which
    /// is affordable because it is bounded by what is on screen and because the
    /// walker never leaves the local volume it started on — the paths reaching
    /// here cannot be a stalled network mount.
    private static func isRestricted(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_RESTRICTED) != 0
    }
}

/// Everything picked for removal, from anywhere on the map.
///
/// Selection used to live and die with the folder on screen, so gathering from
/// four places meant four separate deletes, each quoting its own number. Holding
/// the picks instead makes them one act with one total — which is also the only
/// way the cross-branch estimate can be exact, since two clones of each other
/// free more together than either frees alone and it cannot see that if they
/// never arrive in the same list.
public struct Collector: Sendable, Equatable {
    public private(set) var items: [StorageNode] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var ids: Set<String> { Set(items.map(\.id)) }
    public var urls: [URL] { items.map(\.url) }
    /// What the picks return counted one at a time, which is available the
    /// instant something is picked. A floor, never the answer: `SelectionSpace`
    /// walks the tray to find what they free together.
    public var floorBytes: Int64 { items.reduce(0) { $0 + $1.reclaimableBytes } }
    public var physicalBytes: Int64 { items.reduce(0) { $0 + $1.physicalBytes } }

    /// The tray is what the Trash button acts on, so refusal belongs at the door.
    /// Filtering on the way out would let something appear in the list, be
    /// counted in the total, and then quietly not happen.
    public static func admits(_ node: StorageNode) -> Bool {
        StorageSafety.risk(for: node.url).isTrashable
    }

    public func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    public mutating func add(_ node: StorageNode) {
        guard Self.admits(node) else { return }
        // A folder already carries its children's bytes. Holding both counts them
        // twice, and trashing the parent first leaves the child pointing at a
        // path the parent took with it.
        guard !items.contains(where: { Self.encloses($0.id, node.id) }) else { return }
        items.removeAll { Self.encloses(node.id, $0.id) }
        items.append(node)
    }

    public mutating func remove(id: String) { items.removeAll { $0.id == id } }
    public mutating func removeAll() { items.removeAll() }

    @discardableResult
    public mutating func toggle(_ node: StorageNode) -> Bool {
        if contains(node.id) {
            remove(id: node.id)
            return false
        }
        add(node)
        return contains(node.id)
    }

    /// The separator matters: `Downloads` does not enclose `Downloads-old`.
    private static func encloses(_ ancestor: String, _ path: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
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
