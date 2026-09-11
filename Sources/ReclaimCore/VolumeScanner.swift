import Foundation

/// One directory or large file in the storage tree.
///
/// Children are only kept for entries big enough to be worth showing. Everything
/// below that bar is still counted, in `unlistedBytes`, so a parent's size always
/// equals what the disk actually holds — a treemap whose areas do not add up is
/// worse than no treemap.
public struct StorageNode: Sendable, Identifiable, Equatable {
    public let url: URL
    public let name: String
    /// What this subtree occupies. What the treemap draws.
    ///
    /// Clones are counted once per name, so a folder duplicated by a Finder copy
    /// contributes twice here while the volume holds it once. That is the right
    /// answer to "how big is this folder" and the wrong answer to "what do I get
    /// back", which is why both numbers travel.
    public let physicalBytes: Int64
    /// What deleting this subtree *and nothing else* would return to the volume.
    /// A floor: selecting this alongside the copies it shares with frees more,
    /// and `SelectionSpace` is what works that out.
    public let reclaimableBytes: Int64
    public let isDirectory: Bool
    public let children: [StorageNode]
    public let unlistedBytes: Int64

    public var id: String { url.path }
    public var isExplorable: Bool { isDirectory && !children.isEmpty }

    public init(url: URL,
                name: String,
                physicalBytes: Int64,
                reclaimableBytes: Int64,
                isDirectory: Bool,
                children: [StorageNode],
                unlistedBytes: Int64) {
        self.url = url
        self.name = name
        self.physicalBytes = physicalBytes
        self.reclaimableBytes = reclaimableBytes
        self.isDirectory = isDirectory
        self.children = children
        self.unlistedBytes = unlistedBytes
    }

    /// The same tree with those paths gone and every ancestor's total corrected.
    public func removing(_ paths: Set<String>) -> StorageNode {
        guard !paths.isEmpty else { return self }
        var kept: [StorageNode] = []
        var lost: Int64 = 0
        var lostFree: Int64 = 0
        for child in children {
            if paths.contains(child.id) {
                lost += child.physicalBytes
                lostFree += child.reclaimableBytes
            } else {
                let pruned = child.removing(paths)
                lost += child.physicalBytes - pruned.physicalBytes
                lostFree += child.reclaimableBytes - pruned.reclaimableBytes
                kept.append(pruned)
            }
        }
        return StorageNode(url: url,
                           name: name,
                           physicalBytes: physicalBytes - lost,
                           reclaimableBytes: reclaimableBytes - lostFree,
                           isDirectory: isDirectory,
                           children: kept,
                           unlistedBytes: unlistedBytes)
    }
}

/// Remembers which inodes have already been counted.
///
/// A hard link is one inode reachable by several names, and charging every name
/// would invent free space that deleting cannot deliver — so the first walk to
/// reach an inode claims it and later walks skip it. Sharing one ledger is what
/// lets branches be scanned concurrently and still add up. The lock costs
/// nothing next to the directory read that precedes every claim.
///
/// APFS clones are a different problem and not this one's: they are several
/// inodes over the same blocks, so each name is a genuine, separately deletable
/// thing and belongs in the tree. What they must not do is promise their bytes
/// twice, which is what `StorageNode.reclaimableBytes` is for.
public final class InodeLedger: @unchecked Sendable {
    private struct INode: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private let lock = NSLock()
    private var seen = Set<INode>()

    public init() {}

    func claim(device: dev_t, inode: ino_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(INode(device: device, inode: inode)).inserted
    }
}

/// Where the parallel branch walks report to, each from its own thread.
private final class Assembly: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: Int64] = [:]
    private var done: [String: StorageNode] = [:]
    private var unreadable = Locations()
    private var cloudOnly = Locations()
    private var offVolume = Locations()
    private var firmlinks = 0
    private var unproven: Int64 = 0
    private var location = ""

    func start(_ path: String) { lock.withLock { running[path] = 0 } }

    func tick(_ path: String, bytes: Int64, at place: String) {
        lock.withLock {
            running[path] = bytes
            location = place
        }
    }

    func finish(_ path: String, _ node: StorageNode,
                unreadable: Locations, cloudOnly: Locations, offVolume: Locations,
                firmlinks: Int, unproven: Int64) {
        lock.withLock {
            running[path] = nil
            done[path] = node
            self.unreadable.merge(unreadable)
            self.cloudOnly.merge(cloudOnly)
            self.offVolume.merge(offVolume)
            self.firmlinks += firmlinks
            self.unproven += unproven
        }
    }

    func read() -> (running: [String: Int64], done: [StorageNode], unreadable: Locations,
                    cloudOnly: Locations, offVolume: Locations, firmlinks: Int,
                    unproven: Int64, location: String) {
        lock.withLock {
            (running, Array(done.values), unreadable, cloudOnly, offVolume, firmlinks,
             unproven, location)
        }
    }
}

/// Somewhere the walk could not account for, kept by name as well as by number.
///
/// A count tells someone bytes are missing and leaves them no way to find out
/// which; a folder that reads as empty because it was refused is otherwise
/// indistinguishable from one that is empty. The count stays exact and the list
/// is capped, because a scan of `/` without Full Disk Access refuses thousands
/// of directories and nobody clicks through thousands of rows.
public struct Locations: Sendable, Equatable {
    public private(set) var count = 0
    public private(set) var paths: [String] = []

    private static let sample = 200

    public init() {}

    public mutating func note(_ path: String) {
        count += 1
        if paths.count < Self.sample { paths.append(path) }
    }

    public mutating func merge(_ other: Locations) {
        count += other.count
        paths += other.paths.prefix(Self.sample - min(Self.sample, paths.count))
    }
}

/// Walks a directory tree and measures what is actually allocated on disk.
///
/// Separate from `DiskScanner`, which answers "how big is this one artefact".
/// This answers "where has the space gone", which needs the shape of the tree
/// rather than a single total.
public enum VolumeScanner {
    public struct Result: Sendable {
        public var root: StorageNode
        /// Directories the process was refused. Almost always missing Full Disk
        /// Access; surfacing the count is the difference between "you have no
        /// large files here" and "I was not allowed to look".
        public var unreadable: Locations
        /// Directories deliberately stepped around because their contents are on
        /// a server. They hold no local bytes, so the total is unaffected — but
        /// a OneDrive folder reading as empty needs an explanation.
        public var cloudOnly: Locations
        /// Entries the walk stopped at because their bytes are on a different
        /// volume — a mounted image, a network share. Stopping is correct;
        /// doing it silently is not, because the folder then reads as empty
        /// rather than as unmeasured.
        public var offVolume: Locations
        /// Places where the walk crossed onto another APFS volume in the same
        /// container and kept going. macOS firmlinks the Data volume into `/`,
        /// so a scan of `Macintosh HD` reaches `/Users` and `/Applications`
        /// through one of these; refusing to follow would report the startup
        /// disk as the ~10 GB of sealed system content and nothing else.
        ///
        /// Followed, but not silently: the bytes past a crossing belong to a
        /// different volume than the one the user asked about, and a tool whose
        /// whole claim is that its number is honest has to be able to say so.
        public var firmlinkCrossings: Int
        /// Bytes held by files that share blocks in a way no reference count
        /// describes — a clone that was written to afterwards keeps every block
        /// it did not touch while being dropped from its family's count. Any of
        /// this that lies outside a selection could be holding that selection's
        /// blocks alive, so `SelectionSpace` needs the volume's total to know
        /// what it is allowed to promise.
        public var unprovenBytes: Int64

        public init(root: StorageNode,
                    unreadable: Locations = Locations(),
                    cloudOnly: Locations = Locations(),
                    offVolume: Locations = Locations(),
                    firmlinkCrossings: Int = 0,
                    unprovenBytes: Int64) {
            self.root = root
            self.unreadable = unreadable
            self.cloudOnly = cloudOnly
            self.offVolume = offVolume
            self.firmlinkCrossings = firmlinkCrossings
            self.unprovenBytes = unprovenBytes
        }

        public var unreadableLocations: Int { unreadable.count }
        public var cloudOnlyLocations: Int { cloudOnly.count }
        public var offVolumeLocations: Int { offVolume.count }
        public var unreadablePaths: [String] { unreadable.paths }
        public var cloudOnlyPaths: [String] { cloudOnly.paths }
        public var offVolumePaths: [String] { offVolume.paths }
    }

    /// The volume a directory's contents are really on.
    ///
    /// A bulk read reports the device of the directory the entry was *listed
    /// in*, so a firmlink — the stub macOS uses to graft the Data volume into
    /// `/` — reads as local from both sides and a device test on the bulk value
    /// can never fire. Only a single `getattrlist` on the path resolves the
    /// join. Directories only: a file cannot be a firmlink, and a syscall per
    /// file would be paid three hundred thousand times to learn nothing.
    private static func resolvedDevice(_ path: String, default fallback: dev_t) -> dev_t {
        FileSpace.inspect(path)?.device ?? fallback
    }

    public struct Tick: Sendable {
        /// Everything counted so far across the whole walk.
        public let bytes: Int64
        public let location: String

        public init(bytes: Int64, location: String) {
            self.bytes = bytes
            self.location = location
        }
    }

    /// Everything measured so far, and which branches are still climbing.
    public struct Progress: Sendable {
        public var root: StorageNode
        public var unreadable: Locations
        public var cloudOnly: Locations
        public var offVolume: Locations
        public var firmlinkCrossings: Int
        public var unprovenBytes: Int64
        /// Node ids whose totals are not final yet. The blocks are real; their
        /// sizes will only grow.
        public var measuring: Set<String>
        public var location: String

        public init(root: StorageNode,
                    unreadable: Locations = Locations(),
                    cloudOnly: Locations = Locations(),
                    offVolume: Locations = Locations(),
                    firmlinkCrossings: Int = 0,
                    unprovenBytes: Int64,
                    measuring: Set<String>,
                    location: String) {
            self.root = root
            self.unreadable = unreadable
            self.cloudOnly = cloudOnly
            self.offVolume = offVolume
            self.firmlinkCrossings = firmlinkCrossings
            self.unprovenBytes = unprovenBytes
            self.measuring = measuring
            self.location = location
        }

        public var unreadableLocations: Int { unreadable.count }
        public var cloudOnlyLocations: Int { cloudOnly.count }
        public var offVolumeLocations: Int { offVolume.count }
    }

    public static let defaultListThreshold: Int64 = 24 * 1024 * 1024

    /// - Parameter skipping: absolute paths not to descend into. macOS firmlinks
    ///   the Data volume into `/`, so a scan of the root meets every user file
    ///   twice; the caller naming those mount points is cheaper than the scanner
    ///   trying to detect them, because firmlinked mounts share `st_dev` with
    ///   their parent and so defeat the usual test.
    public static func scan(
        _ url: URL,
        listThreshold: Int64 = defaultListThreshold,
        skipping: Set<String> = [],
        ledger: InodeLedger = InodeLedger(),
        progressInterval: TimeInterval = 0.1,
        onProgress: (Tick) -> Void = { _ in },
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Result {
        guard let probe = FileSpace.inspect(url.path) else { throw ScanError.notFound(url.path) }

        // Staying on one device keeps a scan of / from wandering into network
        // shares and disk images, neither of which is the space the user is
        // looking at.
        let device = probe.device

        var unreadable = Locations()
        var cloudOnly = Locations()
        var offVolume = Locations()
        var firmlinks = 0
        var unproven: Int64 = 0
        var scanned: Int64 = 0
        var lastReport = Date.distantPast

        // The bound travels with the walk rather than being fixed at the root,
        // because once a firmlink has been followed every directory below it is
        // legitimately on the other volume. Compared against the root instead,
        // one crossing into `/System/Library/AssetsV2` reports eighteen thousand.
        func walk(_ directory: URL, device: dev_t) -> StorageNode {
            var total: Int64 = 0
            var free: Int64 = 0
            var listed: [StorageNode] = []
            var unlisted: Int64 = 0

            // Streamed rather than listed whole: a cache directory holds tens of
            // thousands of entries, and buffering one means no progress and no
            // cancel until the last is decoded. `continue` becomes `return true`
            // and `break` becomes `return false`.
            do {
                try FileSpace.stream(directory.path) { listing in
                if isCancelled() { return false }
                let child = directory.appendingPathComponent(listing.name)

                if skipping.contains(child.path) { return true }

                let entry = listing.entry
                guard entry.device == device, !entry.isMountPoint else {
                    // A symlink or socket holds nothing wherever it lives, so
                    // counting one would inflate the tally with entries that
                    // cost the user no space either way.
                    if entry.kind != .other { offVolume.note(child.path) }
                    return true
                }

                switch entry.kind {
                case .directory:
                    if entry.isCloudPlaceholder {
                        cloudOnly.note(child.path)
                        return true
                    }
                    let below = Self.resolvedDevice(child.path, default: device)
                    if below != device { firmlinks += 1 }
                    let node = walk(child, device: below)
                    total += node.physicalBytes
                    free += node.reclaimableBytes
                    if node.physicalBytes >= listThreshold {
                        listed.append(node)
                    } else {
                        unlisted += node.physicalBytes
                    }
                case .file:
                    guard !entry.isCloudPlaceholder,
                          ledger.claim(device: entry.device, inode: entry.inode)
                    else { return true }
                    let bytes = entry.allocatedBytes
                    total += bytes
                    free += entry.reclaimableBytes
                    scanned += bytes
                    if entry.sharing == .partial { unproven += bytes - entry.reclaimableBytes }
                    if bytes >= listThreshold {
                        listed.append(StorageNode(url: child,
                                                  name: listing.name,
                                                  physicalBytes: bytes,
                                                  reclaimableBytes: entry.reclaimableBytes,
                                                  isDirectory: false,
                                                  children: [],
                                                  unlistedBytes: 0))
                    } else {
                        unlisted += bytes
                    }
                case .other:
                    return true
                }

                let now = Date()
                if now.timeIntervalSince(lastReport) >= progressInterval {
                    lastReport = now
                    onProgress(Tick(bytes: scanned, location: directory.path))
                }
                return true
                }
            } catch {
                unreadable.note(directory.path)
                return StorageNode(url: directory,
                                   name: directory.lastPathComponent,
                                   physicalBytes: 0,
                                   reclaimableBytes: 0,
                                   isDirectory: true,
                                   children: [],
                                   unlistedBytes: 0)
            }

            listed.sort { $0.physicalBytes > $1.physicalBytes }
            return StorageNode(url: directory,
                               name: directory.lastPathComponent,
                               physicalBytes: total,
                               reclaimableBytes: free,
                               isDirectory: true,
                               children: listed,
                               unlistedBytes: unlisted)
        }

        if probe.kind == .file {
            let node = StorageNode(url: url,
                                   name: url.lastPathComponent,
                                   physicalBytes: probe.allocatedBytes,
                                   reclaimableBytes: probe.reclaimableBytes,
                                   isDirectory: false,
                                   children: [],
                                   unlistedBytes: 0)
            return Result(root: node,
                          unprovenBytes: probe.sharing == .partial
                              ? probe.allocatedBytes - probe.reclaimableBytes : 0)
        }

        if probe.isCloudPlaceholder {
            return Result(root: StorageNode(url: url,
                                            name: url.lastPathComponent,
                                            physicalBytes: 0,
                                            reclaimableBytes: 0,
                                            isDirectory: true,
                                            children: [],
                                            unlistedBytes: 0),
                          cloudOnly: {
                              var only = Locations()
                              only.note(url.path)
                              return only
                          }(),
                          unprovenBytes: 0)
        }

        let root = walk(url, device: device)
        return Result(root: root,
                      unreadable: unreadable,
                      cloudOnly: cloudOnly,
                      offVolume: offVolume,
                      firmlinkCrossings: firmlinks,
                      unprovenBytes: unproven)
    }

    /// The same walk, split at the root and run across every core.
    ///
    /// A home folder is 90 seconds of one thread waiting on metadata reads, and
    /// nothing on screen until the last one lands. Splitting at the top level
    /// spends the idle cores and — more importantly — lets each branch appear the
    /// moment it is counted, so the map fills in rather than arriving whole.
    ///
    /// The walks share one `InodeLedger`, without which a file hard-linked into
    /// two branches would be charged twice. `onUpdate` is called on whatever
    /// thread got there first, though never two at once.
    public static func scanConcurrently(
        _ url: URL,
        listThreshold: Int64 = defaultListThreshold,
        skipping: Set<String> = [],
        publishInterval: TimeInterval = 0.12,
        onUpdate: @escaping @Sendable (Progress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> Result {
        guard let probe = FileSpace.inspect(url.path) else { throw ScanError.notFound(url.path) }

        // A file, a placeholder, or a root we cannot read has nothing to split.
        // The dataless test has to come before the listing, because listing is
        // the thing that blocks.
        guard probe.kind == .directory, !probe.isCloudPlaceholder,
              let entries = try? FileSpace.contents(of: url.path)
        else {
            let whole = try scan(url, listThreshold: listThreshold, skipping: skipping,
                                 isCancelled: isCancelled)
            onUpdate(Progress(root: whole.root,
                              unreadable: whole.unreadable,
                              cloudOnly: whole.cloudOnly,
                              offVolume: whole.offVolume,
                              unprovenBytes: whole.unprovenBytes,
                              measuring: [],
                              location: url.path))
            return whole
        }

        let device = probe.device
        let ledger = InodeLedger()

        // Directories become parallel branches; root-level files are measured
        // here, because there is nothing to parallelise about a single read.
        var branches: [URL] = []
        var files: [StorageNode] = []
        var fileUnlisted: Int64 = 0
        var fileFree: Int64 = 0
        var fileUnproven: Int64 = 0
        var placeholders = Locations()
        var crossings = Locations()
        var firmlinkSplits = 0

        for listing in entries {
            let child = url.appendingPathComponent(listing.name)
            if skipping.contains(child.path) { continue }
            let entry = listing.entry
            // A branch scan re-derives its own bound from its own root, and
            // `inspect` on a mount point resolves through the mount where a
            // bulk read does not. Left alone, splitting the walk here is what
            // lets a mounted image be counted that the serial walk excludes.
            guard entry.device == device, !entry.isMountPoint else {
                if entry.kind != .other { crossings.note(child.path) }
                continue
            }

            switch entry.kind {
            case .directory:
                if entry.isCloudPlaceholder {
                    placeholders.note(child.path)
                    continue
                }
                // Counted here rather than inside the branch: the branch scan
                // re-derives its bound from its own root, so by the time it
                // runs the crossing it was reached through is behind it.
                if Self.resolvedDevice(child.path, default: device) != device {
                    firmlinkSplits += 1
                }
                branches.append(child)
            case .file:
                guard !entry.isCloudPlaceholder,
                      ledger.claim(device: entry.device, inode: entry.inode)
                else { continue }
                let bytes = entry.allocatedBytes
                fileFree += entry.reclaimableBytes
                if entry.sharing == .partial { fileUnproven += bytes - entry.reclaimableBytes }
                if bytes >= listThreshold {
                    files.append(StorageNode(url: child,
                                             name: listing.name,
                                             physicalBytes: bytes,
                                             reclaimableBytes: entry.reclaimableBytes,
                                             isDirectory: false,
                                             children: [],
                                             unlistedBytes: 0))
                } else {
                    fileUnlisted += bytes
                }
            case .other:
                continue
            }
        }

        let rootFiles = files
        let rootUnlisted = fileUnlisted
        let rootFree = fileFree
        let rootUnproven = fileUnproven
        let rootCloudOnly = placeholders
        let rootOffVolume = crossings
        let rootFirmlinks = firmlinkSplits
        let assembly = Assembly()
        for branch in branches { assembly.start(branch.path) }

        func snapshot() -> Progress {
            let state = assembly.read()
            var listed = rootFiles
            var unlisted = rootUnlisted
            var free = rootFree

            for node in state.done {
                free += node.reclaimableBytes
                if node.physicalBytes >= listThreshold {
                    listed.append(node)
                } else {
                    unlisted += node.physicalBytes
                }
            }
            // A branch still being counted is always listed, however little it
            // has reached so far — a block that appears and grows reads as
            // progress, whereas one that pops in at full size reads as a jump.
            for (path, bytes) in state.running {
                listed.append(StorageNode(url: URL(fileURLWithPath: path),
                                          name: (path as NSString).lastPathComponent,
                                          physicalBytes: bytes,
                                          reclaimableBytes: 0,
                                          isDirectory: true,
                                          children: [],
                                          unlistedBytes: 0))
            }
            listed.sort { $0.physicalBytes > $1.physicalBytes }

            let total = listed.reduce(unlisted) { $0 + $1.physicalBytes }
            let root = StorageNode(url: url,
                                   name: url.lastPathComponent,
                                   physicalBytes: total,
                                   reclaimableBytes: free,
                                   isDirectory: true,
                                   children: listed,
                                   unlistedBytes: unlisted)
            var cloudOnly = rootCloudOnly
            cloudOnly.merge(state.cloudOnly)
            var offVolume = rootOffVolume
            offVolume.merge(state.offVolume)
            return Progress(root: root,
                            unreadable: state.unreadable,
                            cloudOnly: cloudOnly,
                            offVolume: offVolume,
                            firmlinkCrossings: rootFirmlinks + state.firmlinks,
                            unprovenBytes: rootUnproven + state.unproven,
                            measuring: Set(state.running.keys),
                            location: state.location.isEmpty ? url.path : state.location)
        }

        // Branches finish on their own threads and the ticker runs on another.
        // Reading the state and delivering it have to be one step: serialising
        // only the delivery lets two threads read in one order and arrive in the
        // other, which puts a finished folder back to "still counting" and walks
        // the running total backwards.
        let mouth = NSLock()
        func emit() {
            mouth.withLock { onUpdate(snapshot()) }
        }

        emit()

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(publishInterval))
                if Task.isCancelled { break }
                emit()
            }
        }

        // The walk is blocking metadata I/O from end to end, so it belongs on
        // GCD rather than the cooperative pool, whose threads it would occupy
        // wholesale and leave nothing to run the ticker on. `concurrentPerform`
        // also bounds the width to the machine for free.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.concurrentPerform(iterations: branches.count) { index in
                    let branch = branches[index]
                    let result = (try? scan(branch,
                                            listThreshold: listThreshold,
                                            skipping: skipping,
                                            ledger: ledger,
                                            progressInterval: publishInterval,
                                            onProgress: { assembly.tick(branch.path, bytes: $0.bytes, at: $0.location) },
                                            isCancelled: isCancelled))
                        ?? Result(root: StorageNode(url: branch,
                                                    name: branch.lastPathComponent,
                                                    physicalBytes: 0,
                                                    reclaimableBytes: 0,
                                                    isDirectory: true,
                                                    children: [],
                                                    unlistedBytes: 0),
                                  unreadable: {
                                      var refused = Locations()
                                      refused.note(branch.path)
                                      return refused
                                  }(),
                                  unprovenBytes: 0)
                    assembly.finish(branch.path, result.root,
                                    unreadable: result.unreadable,
                                    cloudOnly: result.cloudOnly,
                                    offVolume: result.offVolume,
                                    firmlinks: result.firmlinkCrossings,
                                    unproven: result.unprovenBytes)
                    emit()
                }
                continuation.resume()
            }
        }

        ticker.cancel()
        let final = snapshot()
        mouth.withLock { onUpdate(final) }
        return Result(root: final.root,
                      unreadable: final.unreadable,
                      cloudOnly: final.cloudOnly,
                      offVolume: final.offVolume,
                      firmlinkCrossings: final.firmlinkCrossings,
                      unprovenBytes: final.unprovenBytes)
    }
}
