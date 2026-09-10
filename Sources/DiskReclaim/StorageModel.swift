import AppKit
import Foundation
import Observation
import ReclaimCore

/// Cancellation has to cross into a detached task, where `Task.isCancelled`
/// answers about the detached task rather than the one the user cancelled.
/// A box the scan can poll is the only honest way across that boundary.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

/// Updates arrive from several scan threads and each hops to the main actor on
/// its own, so they can land out of the order they were made in. Every hop
/// takes the newest snapshot rather than the one it was handed: that fixes the
/// order, and folds a burst of arrivals into a single redraw.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: VolumeScanner.Progress?

    func put(_ update: VolumeScanner.Progress) { lock.withLock { latest = update } }

    func take() -> VolumeScanner.Progress? {
        lock.withLock {
            defer { latest = nil }
            return latest
        }
    }
}

@MainActor
@Observable
final class StorageModel {
    struct Root: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        var id: String { url.path }
    }

    /// macOS firmlinks the Data volume into `/`, so every user file appears both
    /// at `/Users` and under here. Walking both doubles a multi-minute scan to
    /// arrive at the same bytes.
    nonisolated static let firmlinkMirror = "/System/Volumes/Data"

    private(set) var roots: [Root] = []
    private(set) var tree: StorageNode?
    private(set) var isScanning = false
    private(set) var progress: VolumeScanner.Tick?
    /// Node ids whose sizes are still climbing. Their blocks are drawn, and
    /// labelled so nobody reads a half-counted folder as a finished one.
    private(set) var measuring: Set<String> = []
    private(set) var unreadableLocations = 0
    /// Folders the scan stepped around because their contents are on a server.
    /// Unlike an unreadable folder this costs the total nothing — but a OneDrive
    /// folder reading as empty is otherwise indistinguishable from a bug.
    private(set) var cloudOnlyLocations = 0
    /// Places the walk stopped at because the bytes past them belong to another
    /// volume — a mounted image, a share, or one of the firmlinks macOS uses to
    /// weave the Data volume into `/`. Scanning `/` meets a few hundred, and
    /// about 9 GB sits behind the ones under `/System/Library` alone.
    private(set) var offVolumeLocations = 0
    /// Points where the walk moved onto another APFS volume in the same
    /// container and carried on. Not a fault and not a gap — the bytes past one
    /// are counted — but they belong to a volume the user did not name.
    private(set) var firmlinkCrossings = 0
    /// Bytes the volume holds for files whose sharing nothing on disk accounts
    /// for. Any of it outside a selection could be keeping that selection's
    /// blocks alive, so the estimate is not allowed to promise past it.
    private(set) var unprovenBytes: Int64 = 0
    private(set) var scannedAt: Date?
    private(set) var lastAction: String?

    var root: Root
    /// Node ids from the tree root down to what is on screen.
    private(set) var trail: [String] = []
    var selection: Set<String> = [] { didSet { reestimate() } }
    /// What the current selection would actually return to the volume.
    private(set) var selectedBytes: Int64 = 0
    /// True while the exact figure is still being worked out. Until it lands,
    /// `selectedBytes` holds the floor, which only ever moves up.
    private(set) var isEstimating = false

    private var scanTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var flag = CancelFlag()
    private let manifest: ManifestStore

    init() {
        // Listing an iCloud placeholder asks the provider to fetch it, which
        // during a disk-space scan downloads the very bytes the user opened the
        // app to reclaim — and blocks until the provider answers, which for a
        // signed-out account is never.
        FileSpace.refuseToMaterialisePlaceholders()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let found = Self.mountedRoots(home: home)
        roots = found
        root = found[0]
        manifest = .standard
    }

    /// Browsable volumes first, then the ones macOS hides. Those hidden volumes
    /// hold tens of gigabytes on a normal Mac and the System tab now names them,
    /// so refusing to open one would be naming a number and then hiding what it
    /// is made of. Nothing in them is removable — `StorageSafety` blocks
    /// everything outside home, `/Applications` and `/Volumes` — so they read
    /// as places to look rather than places to act.
    private static func mountedRoots(home: URL) -> [Root] {
        var browsable = [Root(url: home, name: "Home")]
        var hidden: [Root] = []
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsBrowsableKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: []) ?? []

        for url in mounted {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let root = Root(url: url, name: values.volumeName ?? url.lastPathComponent)
            if values.volumeIsBrowsable == true {
                browsable.append(root)
            } else if VolumeLedger.isSystemVolumeMount(url) {
                hidden.append(root)
            }
        }
        return browsable + hidden
    }

    // MARK: - Where we are

    /// Root first, current directory last.
    var breadcrumb: [StorageNode] {
        guard var node = tree else { return [] }
        var chain = [node]
        for step in trail {
            guard let next = node.children.first(where: { $0.id == step }) else { break }
            node = next
            chain.append(node)
        }
        return chain
    }

    var current: StorageNode? { breadcrumb.last }
    /// Biggest win first. The scanner orders children by what they occupy, which
    /// is what it needs to decide what is worth listing at all; what the user
    /// scans down the column for is what each one gives back.
    var listing: [StorageNode] {
        (current?.children ?? []).sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    func open(_ node: StorageNode) {
        guard node.isExplorable else { return }
        trail.append(node.id)
        selection = []
    }

    func rise(to depth: Int) {
        trail = Array(trail.prefix(depth))
        selection = []
    }

    // MARK: - Scanning

    func choose(_ next: Root) {
        guard next != root else { return }
        root = next
        scan()
    }

    func scan() {
        cancel()
        let target = root.url
        let flag = CancelFlag()
        self.flag = flag

        tree = nil
        trail = []
        selection = []
        progress = nil
        measuring = []
        unreadableLocations = 0
        cloudOnlyLocations = 0
        offVolumeLocations = 0
        firmlinkCrossings = 0
        unprovenBytes = 0
        isScanning = true

        let inbox = Inbox()
        scanTask = Task {
            let result = try? await VolumeScanner.scanConcurrently(
                target,
                skipping: [Self.firmlinkMirror],
                onUpdate: { update in
                    inbox.put(update)
                    Task { @MainActor [weak self] in
                        guard let latest = inbox.take() else { return }
                        self?.absorb(latest, from: flag)
                    }
                },
                isCancelled: { flag.isRaised })

            guard !flag.isRaised else { return }
            tree = result?.root
            unreadableLocations = result?.unreadableLocations ?? 0
            cloudOnlyLocations = result?.cloudOnlyLocations ?? 0
            offVolumeLocations = result?.offVolumeLocations ?? 0
            firmlinkCrossings = result?.firmlinkCrossings ?? 0
            unprovenBytes = result?.unprovenBytes ?? 0
            measuring = []
            scannedAt = Date()
            progress = nil
            isScanning = false
        }
    }

    private func absorb(_ update: VolumeScanner.Progress, from flag: CancelFlag) {
        guard flag === self.flag, !flag.isRaised, isScanning else { return }
        tree = update.root
        measuring = update.measuring
        unreadableLocations = update.unreadableLocations
        cloudOnlyLocations = update.cloudOnlyLocations
        offVolumeLocations = update.offVolumeLocations
        firmlinkCrossings = update.firmlinkCrossings
        unprovenBytes = update.unprovenBytes
        progress = VolumeScanner.Tick(bytes: update.root.reclaimableBytes, location: update.location)
    }

    func cancel() {
        flag.raise()
        scanTask?.cancel()
        isScanning = false
        progress = nil
        measuring = []
    }

    // MARK: - Selection

    var selectedNodes: [StorageNode] { listing.filter { selection.contains($0.id) } }

    /// The tree already knows what each branch frees on its own, and that is a
    /// floor available for nothing. What it cannot know is that two selected
    /// branches are clones of each other and together free what neither frees
    /// alone — and finding that out means walking the selection. So the floor
    /// goes up at once and the real number replaces it a moment later.
    private func reestimate() {
        estimateTask?.cancel()
        let roots = selectedNodes
        selectedBytes = roots.reduce(0) { $0 + $1.reclaimableBytes }
        guard !roots.isEmpty else {
            isEstimating = false
            return
        }

        let urls = roots.map(\.url)
        let unproven = unprovenBytes
        isEstimating = true
        estimateTask = Task { [weak self] in
            // Ticking through a folder should not start a walk per keystroke.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let estimate = await Task.detached(priority: .userInitiated) {
                SelectionSpace.estimate(urls, volumeUnproven: unproven)
            }.value
            guard !Task.isCancelled else { return }
            self?.selectedBytes = estimate.bytes
            self?.isEstimating = false
        }
    }

    var selectionIsTrashable: Bool {
        !selectedNodes.isEmpty && selectedNodes.allSatisfy { risk(of: $0).isTrashable }
    }

    func toggle(_ node: StorageNode) {
        guard !measuring.contains(node.id) else { return }
        if selection.contains(node.id) { selection.remove(node.id) } else { selection.insert(node.id) }
    }

    func risk(of node: StorageNode) -> StorageRisk { StorageSafety.risk(for: node.url) }

    /// The worst thing in the selection decides how loudly the sheet talks.
    var selectionRisk: StorageRisk {
        let order: [StorageRisk] = [.blocked, .risky, .yours, .safe]
        return order.first { worst in selectedNodes.contains { risk(of: $0) == worst } } ?? .safe
    }

    // MARK: - Removing

    func trashSelected() {
        let targets = selectedNodes.filter { risk(of: $0).isTrashable }
        guard !targets.isEmpty else { return }

        var moved: Int64 = 0
        var gone: Set<String> = []
        var failed = 0

        for node in targets {
            do {
                try Trash.put(node.url)
                moved += node.reclaimableBytes
                gone.insert(node.id)
                record(node)
            } catch {
                failed += 1
            }
        }

        tree = tree?.removing(gone)
        selection = []
        lastAction = failed == 0
            ? "Moved \(humanBytes(moved)) to the Trash. Empty it to get the space back."
            : "Moved \(humanBytes(moved)) to the Trash. \(failed) could not be moved."
    }

    /// Catalogued caches are logged before deletion, because the recorded recipe
    /// is the only way back and a lost log means lost bytes. Here the way back is
    /// the system Trash, which exists whether or not this log write succeeds, so
    /// the file moves first and the log follows.
    private func record(_ node: StorageNode) {
        try? manifest.append(ManifestEntry(
            artefactID: "storage.trash",
            path: node.url.path,
            tier: .irreplaceable,
            bytesFreed: node.reclaimableBytes,
            recipe: Recipe(kind: .trash,
                           command: "In Finder, open the Trash and choose Put Back")))
    }

    func reveal(_ node: StorageNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
}
