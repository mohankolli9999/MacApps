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

    /// Adds to a branch's running total rather than setting it: the bytes now
    /// arrive from whichever worker happened to take a directory, so no single
    /// caller knows what the branch has reached so far.
    func advance(_ path: String, by bytes: Int64, at place: String) {
        lock.withLock {
            running[path, default: 0] += bytes
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

/// Everything a walk collects that is not bytes.
private struct Tally {
    var unreadable = Locations()
    var cloudOnly = Locations()
    var offVolume = Locations()
    var firmlinks = 0
    var unproven: Int64 = 0

    mutating func merge(_ other: Tally) {
        unreadable.merge(other.unreadable)
        cloudOnly.merge(other.cloudOnly)
        offVolume.merge(other.offVolume)
        firmlinks += other.firmlinks
        unproven += other.unproven
    }
}

/// A directory whose own listing is done but whose subtree is not.
///
/// Recursion gets the tree for free — a child's node is a return value. A work
/// queue cannot, because the worker that lists a directory is rarely the one
/// that finishes its children. So every directory keeps a shelf, and whichever
/// child happens to finish last is the one that folds the shelf into its
/// parent. `pending` counts what is outstanding: the directory's own listing,
/// plus one for each subdirectory handed to the queue. Only the frontier's lock
/// touches any of it.
private final class Shelf {
    let url: URL
    let parent: Shelf?
    /// The top-level branch this sits under, which is the key the assembly and
    /// the progress display know it by however deep it actually is.
    let branch: String
    /// Carried rather than re-probed: once a firmlink has been followed, every
    /// directory below it is legitimately on the other volume.
    let device: dev_t
    var listed: [StorageNode] = []
    var total: Int64 = 0
    var free: Int64 = 0
    var unlisted: Int64 = 0
    var tally = Tally()
    var pending = 1
    var sealed = false

    init(url: URL, parent: Shelf?, branch: String, device: dev_t) {
        self.url = url
        self.parent = parent
        self.branch = branch
        self.device = device
    }

    func seal(_ listThreshold: Int64) -> StorageNode {
        sealed = true
        listed.sort { $0.physicalBytes > $1.physicalBytes }
        return StorageNode(url: url,
                           name: url.lastPathComponent,
                           physicalBytes: total,
                           reclaimableBytes: free,
                           isDirectory: true,
                           children: listed,
                           unlistedBytes: unlisted)
    }

    func absorb(_ node: StorageNode, _ below: Tally, _ listThreshold: Int64) {
        total += node.physicalBytes
        free += node.reclaimableBytes
        if node.physicalBytes >= listThreshold {
            listed.append(node)
        } else {
            unlisted += node.physicalBytes
        }
        tally.merge(below)
    }
}

/// Directories waiting to be walked, handed out one at a time.
///
/// Splitting the work at the root instead gives each thread a whole top-level
/// branch and nothing to do once it lands — and `~/Library` alone holds over
/// half of a home folder's directories, so most threads finish early and then
/// wait for one. The ceiling that imposes is a property of the tree's shape,
/// not of the machine, so it does not lift on faster hardware. Handing out
/// single directories keeps every worker fed until the tree is exhausted.
///
/// Termination counts outstanding directories rather than idle workers,
/// because an empty queue means "nothing to hand out yet", which is not the
/// same as "nothing left": a worker still listing will produce more.
private final class Frontier: @unchecked Sendable {
    private let gate = NSCondition()
    private var waiting: [Shelf] = []
    private var outstanding = 0
    private var stopped = false

    init(_ shelves: [Shelf]) {
        waiting = shelves
        outstanding = shelves.count
        stopped = shelves.isEmpty
    }

    func push(_ shelves: [Shelf]) {
        guard !shelves.isEmpty else { return }
        gate.lock()
        waiting.append(contentsOf: shelves)
        outstanding += shelves.count
        // One wake per directory: a broadcast sends every idle worker to race
        // for the same one and go back to sleep.
        for _ in shelves.indices { gate.signal() }
        gate.unlock()
    }

    func finished() {
        gate.lock()
        outstanding -= 1
        if outstanding == 0 {
            stopped = true
            gate.broadcast()
        }
        gate.unlock()
    }

    func stop() {
        gate.lock()
        stopped = true
        gate.broadcast()
        gate.unlock()
    }

    /// Depth first, so the frontier stays short and a subtree is finished and
    /// released rather than half-built across the whole disk at once.
    func next() -> Shelf? {
        gate.lock()
        defer { gate.unlock() }
        while !stopped {
            if let shelf = waiting.popLast() { return shelf }
            gate.wait()
        }
        return nil
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
    /// Where a directory the scan could not list belongs in the tally.
    ///
    /// `unreadable` means "I was not allowed to look", and that is how the
    /// display reads it — a count that says every total above is low. Two other
    /// things reach this point and neither is that. A directory that existed
    /// when its parent was listed and was gone by the time it was opened leaves
    /// nothing missing from the total, because there is nothing left to count.
    /// A dataless one is not a failure at all: its bytes are on a server, so
    /// none of them are on this disk, and that is the complete answer.
    ///
    /// Worth separating because none of the three is told apart by the disk.
    /// `~/Library/Caches` churns constantly, so the faster the walk reaches a
    /// directory after listing its parent, the fewer vanished ones it meets —
    /// which had the parallel walk reporting several dozen refusals that the
    /// serial one did not.
    ///
    /// Anything that is not a listing error at all has no better home than
    /// unreadable: the bytes were not counted and the scan cannot say why.
    private static func disposition(of error: Error) -> FileSpace.ListingError.Disposition {
        (error as? FileSpace.ListingError)?.disposition ?? .unreadable
    }

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
        //
        // It also bounds which volumes the accounting rules have to know about.
        // Refusing mount points means a walk of / touches two devices — the
        // sealed system volume and the Data volume it firmlinks onto — and both
        // are recorded before the walk starts. Descending into mounts instead
        // reaches twelve, including ones that appear mid-scan and autofs
        // automounts that cannot be enumerated up front at all, and every
        // unrecorded device silently falls back to `exact`, which promises the
        // user bytes a snapshot is holding. Relaxing this guard means moving
        // accounting to per-device resolution first.
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
                switch Self.disposition(of: error) {
                case .unreadable: unreadable.note(directory.path)
                case .elsewhere: cloudOnly.note(directory.path)
                case .vanished: break
                }
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
        var branches: [(url: URL, device: dev_t)] = []
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
                // Counted here rather than inside the branch: the bound travels
                // down with the walk, so by the time the branch runs, the
                // crossing it was reached through is behind it.
                let below = Self.resolvedDevice(child.path, default: device)
                if below != device { firmlinkSplits += 1 }
                branches.append((child, below))
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
        for branch in branches { assembly.start(branch.url.path) }

        @Sendable func snapshot() -> Progress {
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
        @Sendable func emit() {
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

        let stems = branches.map {
            Shelf(url: $0.url, parent: nil, branch: $0.url.path, device: $0.device)
        }
        let frontier = Frontier(stems)
        let shelves = NSLock()

        /// Marks one of a shelf's obligations met, and folds every shelf that
        /// leaves with nothing outstanding into its parent. Iterative rather
        /// than recursive because the cascade runs the depth of the tree.
        @Sendable func settle(_ start: Shelf) {
            var completed: (Shelf, StorageNode)?
            shelves.withLock {
                var cursor: Shelf? = start
                while let current = cursor {
                    current.pending -= 1
                    guard current.pending == 0 else { return }
                    let node = current.seal(listThreshold)
                    guard let parent = current.parent else {
                        completed = (current, node)
                        return
                    }
                    parent.absorb(node, current.tally, listThreshold)
                    cursor = parent
                }
            }
            guard let (branch, node) = completed else { return }
            assembly.finish(branch.branch, node,
                            unreadable: branch.tally.unreadable,
                            cloudOnly: branch.tally.cloudOnly,
                            offVolume: branch.tally.offVolume,
                            firmlinks: branch.tally.firmlinks,
                            unproven: branch.tally.unproven)
            emit()
        }

        @Sendable func work() {
            while let shelf = frontier.next() {
                if isCancelled() { frontier.stop(); return }

                var total: Int64 = 0
                var free: Int64 = 0
                var unlisted: Int64 = 0
                var scanned: Int64 = 0
                var listed: [StorageNode] = []
                var children: [Shelf] = []
                var tally = Tally()
                let bound = shelf.device

                // Restarts from nothing each time so the listing can be asked
                // for twice. Keeping a partial read and topping it up would
                // count whatever arrived before the failure a second time.
                func attempt() throws {
                    total = 0
                    free = 0
                    unlisted = 0
                    scanned = 0
                    listed = []
                    children = []
                    tally = Tally()
                    try FileSpace.stream(shelf.url.path) { listing in
                        if isCancelled() { return false }
                        let child = shelf.url.appendingPathComponent(listing.name)
                        if skipping.contains(child.path) { return true }

                        let entry = listing.entry
                        guard entry.device == bound, !entry.isMountPoint else {
                            // A symlink or socket holds nothing wherever it
                            // lives, so counting one would inflate the tally
                            // with entries that cost the user no space.
                            if entry.kind != .other { tally.offVolume.note(child.path) }
                            return true
                        }

                        switch entry.kind {
                        case .directory:
                            if entry.isCloudPlaceholder {
                                tally.cloudOnly.note(child.path)
                                return true
                            }
                            let below = Self.resolvedDevice(child.path, default: bound)
                            if below != bound { tally.firmlinks += 1 }
                            children.append(Shelf(url: child, parent: shelf,
                                                  branch: shelf.branch, device: below))
                        case .file:
                            guard !entry.isCloudPlaceholder,
                                  ledger.claim(device: entry.device, inode: entry.inode)
                            else { return true }
                            let bytes = entry.allocatedBytes
                            total += bytes
                            free += entry.reclaimableBytes
                            scanned += bytes
                            if entry.sharing == .partial {
                                tally.unproven += bytes - entry.reclaimableBytes
                            }
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
                        return true
                    }
                }

                var failure: Error?
                do {
                    try attempt()
                } catch {
                    failure = error
                }

                // Ask once more before calling it a refusal. A cloud file
                // provider being asked for sixteen directories at once
                // intermittently turns one down and then hands it over without
                // complaint on the next ask — the serial walk never asked fast
                // enough to provoke it, so the parallel walk was reporting
                // locations as unlistable that nothing was wrong with. That
                // lands the user under an offer of Full Disk Access, which is
                // the wrong thing to tell someone whose permissions are fine.
                // A directory that is genuinely refused costs one extra syscall
                // to confirm it. The errors that cannot change are not asked
                // twice: retrying a dataless directory is measurably wasted.
                if let error = failure, Self.disposition(of: error).isWorthAskingAgain {
                    do {
                        try attempt()
                        failure = nil
                    } catch {
                        failure = error
                    }
                }

                if let failure {
                    // What the serial walk reports for a directory it could not
                    // list: nothing, and no children. Notes taken before the
                    // read failed are kept, because they did happen.
                    total = 0
                    free = 0
                    unlisted = 0
                    scanned = 0
                    listed = []
                    children = []
                    switch Self.disposition(of: failure) {
                    case .unreadable: tally.unreadable.note(shelf.url.path)
                    case .elsewhere: tally.cloudOnly.note(shelf.url.path)
                    case .vanished: break
                    }
                }

                shelves.withLock {
                    // The children are counted before they are handed out. One
                    // that finished before its parent's count included it would
                    // fold the parent while the rest of the subtree is still
                    // being walked, and the branch would land short.
                    shelf.pending += children.count
                    shelf.total += total
                    shelf.free += free
                    shelf.unlisted += unlisted
                    shelf.listed += listed
                    shelf.tally.merge(tally)
                }
                frontier.push(children)
                assembly.advance(shelf.branch, by: scanned, at: shelf.url.path)
                settle(shelf)
                frontier.finished()
            }
        }

        // The walk is blocking metadata I/O from end to end, so it belongs on
        // threads of its own rather than the cooperative pool, whose threads it
        // would occupy wholesale and leave nothing to run the ticker on. Plain
        // threads rather than a GCD pool because these are meant to sit blocked:
        // a pool sized to the machine would hand out fewer than asked for and
        // the workers waiting for work would never be woken.
        let width = min(16, max(2, ProcessInfo.processInfo.activeProcessorCount * 2))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let crew = DispatchGroup()
            for index in 0 ..< width {
                crew.enter()
                let worker = Thread {
                    work()
                    crew.leave()
                }
                worker.name = "reclaim.walk.\(index)"
                worker.qualityOfService = .userInitiated
                worker.start()
            }
            crew.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }

        // A cancelled walk leaves shelves that will never reach zero, and a
        // branch that never settles never reaches the assembly at all — the
        // tree would come back missing whole top-level folders rather than
        // merely short, and the display would keep marking them as measuring.
        for stem in stems where !stem.sealed {
            assembly.finish(stem.branch, stem.seal(listThreshold),
                            unreadable: stem.tally.unreadable,
                            cloudOnly: stem.tally.cloudOnly,
                            offVolume: stem.tally.offVolume,
                            firmlinks: stem.tally.firmlinks,
                            unproven: stem.tally.unproven)
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
