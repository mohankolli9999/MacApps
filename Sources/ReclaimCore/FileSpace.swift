import Foundation

// Not surfaced in Swift's Darwin overlay.
private let ATTR_CMNEXT_PRIVATESIZE: UInt32 = 0x0000_0008
private let ATTR_CMNEXT_REALDEVID: UInt32 = 0x0000_0040
private let ATTR_CMNEXT_CLONEID: UInt32 = 0x0000_0100
private let ATTR_CMNEXT_EXT_FLAGS: UInt32 = 0x0000_0200
private let ATTR_CMNEXT_CLONE_REFCNT: UInt32 = 0x0000_1000
private let FSOPT_PACK_INVAL_ATTRS: UInt32 = 0x0000_0008
private let FSOPT_ATTR_CMN_EXTENDED: UInt32 = 0x0000_0020
private let EF_SHARES_ALL_BLOCKS: UInt64 = 0x0000_0040
private let EF_MAY_SHARE_BLOCKS: UInt64 = 0x0000_0001
private let VREG: UInt32 = 1
private let VDIR: UInt32 = 2

/// What one file costs the disk, and what deleting it would actually give back.
///
/// `st_blocks` — what every disk tool reaches for, this one included until now —
/// counts the blocks a file *occupies*, not the blocks that would come free. On
/// APFS those differ whenever a file was copied in Finder or cloned by an
/// installer: both copies report the full size, and deleting either frees
/// nothing, because the other still holds the blocks.
///
/// One `getattrlist` answers all of it, and answers everything `lstat` would
/// have, so this replaces the stat rather than adding to it.
public enum FileSpace {
    public enum Kind: Sendable, Equatable {
        case file
        case directory
        case other
    }

    /// Who else holds this file's blocks.
    public enum Sharing: Sendable, Equatable {
        /// Nobody. Deleting the file returns everything it occupies.
        case none
        /// Every block is shared, with `familySize` files in total including this
        /// one. They all carry the same `familyID`, which is how a selection can
        /// tell whether it holds the whole family or only part of it.
        case whole(familySize: Int, familyID: UInt64)
        /// Some blocks are shared and some are not, and APFS will not say which
        /// or with whom. Writing to a clone un-shares the blocks it touches,
        /// gives the file a fresh family id, and drops it from the old family's
        /// reference count — *and* drops the file it was cloned from as well.
        /// Both then report a family of one while still holding each other's
        /// blocks, so a reference count is no evidence of sole ownership here.
        case partial
    }

    public struct Entry: Sendable, Equatable {
        public let kind: Kind
        /// The device the bytes are really on. macOS firmlinks the Data volume
        /// into `/`, so `st_dev` reads the same on both sides of the join and
        /// cannot bound a walk; this can.
        public let device: dev_t
        public let inode: ino_t
        /// A cloud provider's stand-in for something whose bytes live on a
        /// server. Nothing local is allocated, so there is nothing to count —
        /// and listing one asks the provider to fetch it, which during a
        /// disk-space scan downloads the very bytes the user opened the app to
        /// reclaim, and blocks for as long as the provider takes to answer.
        public let isCloudPlaceholder: Bool
        /// Another filesystem is mounted here. `device` cannot see it: a bulk
        /// read describes the directory the mount covers, not the volume that
        /// covers it, so the entry looks local right up until the walk steps
        /// inside and every child turns out to be somewhere else.
        public let isMountPoint: Bool
        /// What the file claims to hold. Larger than the allocation for a sparse
        /// file, smaller for a compressed one; never what deleting it frees.
        public let logicalBytes: Int64
        /// What the file occupies. What a treemap should draw.
        public let allocatedBytes: Int64
        /// What deleting this file *on its own* would return to the volume.
        public let reclaimableBytes: Int64
        public let sharing: Sharing
    }

    /// Stops the kernel from materialising cloud placeholders on this process's
    /// behalf. The inherited policy is ON despite what the man page says, which
    /// is how a scan ends up hanging on a signed-out OneDrive folder rather than
    /// failing fast. Call once, before any walking.
    public static func refuseToMaterialisePlaceholders() {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                       IOPOL_SCOPE_PROCESS,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    /// How far a volume's own numbers can be taken at their word.
    ///
    /// A private size of zero has several causes and they do not share an answer,
    /// so the ambiguity is resolved once per volume instead of guessed at per
    /// file. Guessing per file is what this replaces, and it was wrong in the
    /// direction that matters: it read the zero as "the kernel did not account
    /// for these bytes, so credit the allocation", which is precisely backwards
    /// when the bytes are unaccounted *because* something else is holding them.
    public enum VolumeAccounting: Sendable, Equatable {
        /// The volume clones files and nothing is pinning it, so the private size
        /// is the literal answer and a resource fork the file owns outright can
        /// be added to it.
        case exact
        /// Nothing on the volume can be deleted, so nothing on it is reclaimable
        /// whatever its files report. The sealed system volume is the case that
        /// matters: it is mounted from a snapshot, which zeroes every private
        /// size on it, and that snapshot does not appear in the snapshot list —
        /// so asking the mount whether it is writable is what makes this right
        /// rather than an accident of which other rule happens to catch it.
        case readOnly
        /// A snapshot is holding this volume's blocks. Deleting a file the
        /// snapshot contains frees nothing until it expires, and the kernel says
        /// so by reporting no private bytes. Nothing may be added on top of that.
        case pinned
        /// The volume has no concept of sharing, so it answers these attributes
        /// with zeroes that mean "not supported" rather than "no private bytes".
        /// Allocated size is the only number it has, and it is the right one:
        /// with no clones there is nothing to be wrong about.
        case allocation
    }

    /// Decided per device, before walking, and read from every walking thread
    /// without further synchronisation — the same discipline as the placeholder
    /// policy above.
    ///
    /// Keyed by device because a scan covers external drives as well as the boot
    /// volume, and neither a snapshot nor a missing capability on one says
    /// anything about the other. An unrecorded device is treated as `exact`,
    /// which under-reports on a volume that needed `allocation` and never
    /// over-reports — the asymmetry that decides every default here, since an
    /// under-report costs the user an opportunity and an over-report makes the
    /// delete button lie.
    public nonisolated(unsafe) static var volumeAccounting: [dev_t: VolumeAccounting] = [:]

    /// The read-only and snapshot tests look interchangeable on this machine and
    /// are not: `/System/Volumes/Update/mnt1` is sealed with every file at a
    /// private size of zero, yet its mount flags have `MNT_RDONLY` clear, so only
    /// the snapshot test catches it. Collapsing the two because they happen to
    /// agree on `/` would put that volume back on `.exact` and promise every byte
    /// of it.
    ///
    /// - Parameter snapshotted: whether a snapshot is holding the volume, which
    ///   this cannot ask for itself without dragging `diskutil` into the hot path.
    public static func record(volumeAt url: URL, snapshotted: Bool) {
        guard let device = inspect(url.path)?.device else { return }
        var mount = statfs()
        let readOnly = statfs(url.path, &mount) == 0
            && mount.f_flags & UInt32(MNT_RDONLY) != 0
        volumeAccounting[device] = readOnly ? .readOnly
            : snapshotted ? .pinned
            : clonesFiles(at: url.path) ? .exact : .allocation
    }

    /// Whether the volume holding `path` can share blocks between files at all.
    ///
    /// Without this the zeroes an HFS+ or exFAT volume returns for the fork
    /// attributes read as "this file frees nothing", and an entire external drive
    /// reports as having nothing to reclaim.
    public static func clonesFiles(at path: String) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var answer = (length: UInt32(0), capabilities: vol_capabilities_attr_t())
        guard getattrlist(path, &list, &answer, MemoryLayout.size(ofValue: answer), 0) == 0
        else { return false }
        // `.1` is `VOL_CAPABILITIES_INTERFACES`, which Swift imports as a tuple
        // rather than an array. A capability only means anything when the volume
        // also claims to know the question, hence both words.
        let supported = answer.capabilities.valid.1
        let present = answer.capabilities.capabilities.1
        return supported & UInt32(VOL_CAP_INT_CLONE) != 0
            && present & UInt32(VOL_CAP_INT_CLONE) != 0
    }

    public struct Listing: Sendable, Equatable {
        public let name: String
        public let entry: Entry
    }

    /// Why a directory could not be listed. Rendering a refused directory as an
    /// empty one is the failure that makes a disk tool untrustworthy: it reports
    /// space as reclaimable that was never looked at.
    public enum ListingError: Error, Equatable {
        case denied
        case missing
        /// The directory's contents live on a provider's server, and `forbid()`
        /// has told the kernel this process will not fetch them. It cannot
        /// answer without the round trip it is not allowed to make, and returns
        /// a deadlock error rather than quietly downloading the user's drive.
        case dataless
        case failed(Int32)

        /// Where a directory that could not be listed belongs in the totals.
        public enum Disposition: Sendable, Equatable {
            /// Bytes the scan could not see, so every total above is low.
            case unreadable
            /// Not a failure. None of those bytes are on this disk, which is
            /// the complete answer for a tool measuring what is reclaimable
            /// here — filing it as unreadable would report the scan as blocked
            /// when it knew.
            case elsewhere
            /// Gone between its parent listing it and this thread reaching it.
            case vanished

            /// Under a wide parallel walk a directory can be refused once and
            /// handed over without complaint on the next ask, so a refusal is
            /// worth confirming before it is believed. The other two are
            /// settled: a dataless directory refuses identically every time —
            /// measured elsewhere at 0 successes in 20 retries — and a vanished
            /// one has nothing to come back to.
            public var isWorthAskingAgain: Bool { self == .unreadable }
        }

        public var disposition: Disposition {
            switch self {
            case .dataless: .elsewhere
            case .missing: .vanished
            case .denied, .failed: .unreadable
            }
        }

        public var isWorthAskingAgain: Bool { disposition.isWorthAskingAgain }

        public static func of(_ code: Int32) -> ListingError {
            switch code {
            case EACCES, EPERM: .denied
            case ENOENT: .missing
            case EDEADLK: .dataless
            default: .failed(code)
            }
        }
    }

    /// `ATTR_CMNEXT_PRIVATESIZE` is by far the most expensive field here — the
    /// other four are inode values the kernel already holds, while this one
    /// makes it work out which of the file's blocks are shared. Measured on this
    /// home folder it is about seventeen seconds of a forty-eight second scan,
    /// and dropping it from the bulk read makes the scan 1.56x faster.
    ///
    /// It cannot be dropped, and the reason is worth keeping because the idea is
    /// an obvious one to have twice. The plan was to leave it out here and re-read
    /// only the files whose flags say they share blocks, on the theory that
    /// everything else has a private size equal to its allocated size. Sharing is
    /// not the only thing that separates those two numbers. Measured over 1.57M
    /// files: 24 compressed files report a private size of zero because decmpfs
    /// keeps their data in an extended attribute, 33 sparse and purgeable files
    /// report less than they occupy, and — the one that ends the idea — two files
    /// carrying *no flags at all* report zero against real allocation, because
    /// their data is in a resource fork that the private size does not count and
    /// nothing in the metadata advertises. Gating on every storage flag the
    /// kernel does expose still leaked those two, still had to re-read a third of
    /// all files, and left no way to know what else is unflagged. A scan that is
    /// 1.56x faster and sometimes promises back bytes that will not arrive is not
    /// the trade this app makes.
    private static func request() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = ATTR_CMN_RETURNED_ATTRS
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        list.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        list.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_RSRCALLOCSIZE)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE
            | ATTR_CMNEXT_REALDEVID
            | ATTR_CMNEXT_CLONEID
            | ATTR_CMNEXT_EXT_FLAGS
            | ATTR_CMNEXT_CLONE_REFCNT)
        return list
    }

    private static let options = UInt32(FSOPT_NOFOLLOW)
        | FSOPT_ATTR_CMN_EXTENDED
        | FSOPT_PACK_INVAL_ATTRS

    /// Decodes one record. Both calls request the same attributes so that the
    /// same file measures the same however the scanner reached it.
    ///
    /// Fields arrive packed in bit order, not the order they were asked for, and
    /// with no alignment padding. `FSOPT_PACK_INVAL_ATTRS` is what makes that
    /// layout the same for both calls, and without it they break in opposite
    /// directions on a volume that lacks the extended fork attributes. Measured
    /// on HFS+: a bulk read returns a fork mask of zero yet reserves all
    /// thirty-two bytes anyway, so honouring the mask slides the cursor into the
    /// name; a single read returns a mask of `REALDEVID` alone and reserves
    /// nothing, so reading unconditionally takes the device id as the private
    /// size — sixteen megabytes for a sixty-four kilobyte file. Neither decoder
    /// is right for both. With the flag both reserve the space, both claim all
    /// five reserved whether or not the filesystem has heard of them, and both
    /// zero-fill the rest: reading unconditionally is then correct everywhere,
    /// and the zeros are interpreted below rather than believed. It does *not*
    /// reserve space for attributes that do not apply to the object at hand,
    /// which is why a directory has no allocated size and that one field still
    /// has to be read from the mask.
    ///
    /// The fork region is laid out by the request, not by the reply, so the fork
    /// mask must not be used the way the dirattr and fileattr masks are. What
    /// makes reading it unconditionally correct is that the field list below is
    /// exactly the set requested above — that equality is the invariant, not the
    /// unconditionality. Add a bit to one without adding a step to the other and
    /// the cursor breaks with no compiler error and no mask to catch it.
    ///
    /// Measured on a read-only HFS volume: `REALDEVID` comes back absent from
    /// the mask — `0x1348` asked, `0x1308` returned — yet the record still
    /// reserves all thirty-two bytes, and the name begins exactly where reading
    /// all five puts the cursor. Skipping the four bytes the mask disowns lands
    /// four short and reads `EXT_FLAGS`, which carries the sharing bits every
    /// reclaim decision rests on, half out of the neighbouring field. The
    /// reserved slot is actively zeroed rather than left as it was — checked
    /// against a buffer poisoned with `0xAA` and `0xFF`, which matters because
    /// this one is reused across batches — so `fallbackDevice` covers the
    /// absent id instead of inheriting the last record's.
    ///
    /// - Parameter fallbackDevice: what to report when the filesystem does not
    ///   supply a real device id. Seen once on a freshly mounted HFS+ image,
    ///   where a bulk read returned zero for a file whose single read gave the
    ///   right answer, and not reproducible under the options above since. It is
    ///   reproducible with `FSOPT_PACK_INVAL_ATTRS` dropped, where every bulk
    ///   entry on HFS+ reads zero — which does not prove that was the original
    ///   cause, only that a filesystem answering this way is a real state and
    ///   not a one-off. Zero is not a device any mounted volume has, and the
    ///   scanner drops entries whose device is not the volume's — so left alone
    ///   this undercounts a drive with no error to show for it. The directory's
    ///   own device is the right answer for anything inside it on a filesystem
    ///   with no firmlinks, which is every filesystem that could get here.
    private static func decode(_ raw: UnsafeRawBufferPointer,
                               at start: Int,
                               fallbackDevice: dev_t) -> (length: Int, Listing)? {
        var offset = start
        func take<T>(_: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        let length = Int(take(UInt32.self))
        guard length >= MemoryLayout<UInt32>.size, start + length <= raw.count else { return nil }

        let returned = take(attribute_set_t.self)
        let nameField = offset
        let name = take(attrreference_t.self)
        let objectType = take(UInt32.self)
        let flags = take(UInt32.self)
        let fileID = take(UInt64.self)
        // Groups pack in their own order too, and dirattr comes before fileattr.
        let mountStatus = returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0
            ? take(UInt32.self) : 0
        // Bit order, not request order: TOTALSIZE (0x2) precedes ALLOCSIZE (0x4).
        let logical = returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0
            ? take(Int64.self) : 0
        let allocated = returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0
            ? take(Int64.self) : 0
        let resourceFork = returned.fileattr & attrgroup_t(ATTR_FILE_RSRCALLOCSIZE) != 0
            ? take(Int64.self) : 0
        let privateBytes = take(Int64.self)
        let realDevice = take(Int32.self)
        let familyID = take(UInt64.self)
        let extendedFlags = take(UInt64.self)
        let referenceCount = take(UInt32.self)

        // The layout above is an assumption about a syscall, and the failure it
        // guards against is silent: every field still parses, into a plausible
        // wrong number. A name that does not sit in the space left over after
        // the fixed fields means the assumption broke.
        let text = nameField + Int(name.attr_dataoffset)
        let size = Int(name.attr_length)
        guard text >= offset, size > 0, text + size <= start + length else { return nil }

        let kind: Kind
        switch objectType {
        case VREG: kind = .file
        case VDIR: kind = .directory
        default: kind = .other
        }

        let device = realDevice != 0 ? dev_t(realDevice) : fallbackDevice
        let accounting = volumeAccounting[device] ?? .exact

        // The private size measures the data fork alone, so a file holding bytes
        // in a resource fork looks short by exactly that much — and a shortfall
        // is otherwise read as sharing, which filed ordinary files under bytes
        // nobody can account for. Only added when nothing about the file is
        // shared: cloning copies the resource fork and goes on reporting its
        // full allocated size on both copies, so crediting a sharer would
        // promise the same blocks twice. `EF_MAY_SHARE_BLOCKS` is included in
        // that test even though it is sticky and survives the deletion of the
        // last partner, because the cost of believing it is an under-report.
        //
        // A compressed file keeps its data outside the ordinary file extents, so
        // it reports no private bytes against real allocation and reads exactly
        // like a file a snapshot is holding. The allocated size is the right
        // answer for the first and catastrophically wrong for the second, and no
        // per-file attribute tells them apart — which is why this substitution
        // is confined to `exact`. That mode means no snapshot on this volume, so
        // the pinned cause is excluded by construction rather than by guesswork.
        // It is still worth having: of 2,967 compressed files under
        // /Applications, 1,541 carry no sharing bits and account for 213.9 MiB,
        // and the compressed file is typically the largest binary in an app
        // bundle, so dropping it tells the user that deleting a 24.8 MB
        // executable would free nothing. The other 1,426 ship pre-cloned by
        // their installer, which is why the sharing test cannot be skipped on
        // the grounds that compression implies a private payload.
        let sharesEverything = extendedFlags & EF_SHARES_ALL_BLOCKS != 0
        let sharesNothing = extendedFlags & (EF_MAY_SHARE_BLOCKS | EF_SHARES_ALL_BLOCKS) == 0
        let compressed = flags & UInt32(UF_COMPRESSED) != 0
        let reclaimable: Int64
        switch accounting {
        case .readOnly: reclaimable = 0
        case .allocation: reclaimable = allocated
        case .pinned: reclaimable = privateBytes
        case .exact:
            // Allocated size already covers both forks, so the compressed branch
            // must not also add the resource fork — decmpfs stores the larger
            // payloads there, and it would be counted twice.
            reclaimable = privateBytes == 0 && compressed && !sharesEverything
                ? allocated
                : privateBytes + (sharesNothing ? resourceFork : 0)
        }

        // A pinned volume never reports a clone family, however plainly the file
        // says it is in one. A family whose members are all selected is credited
        // its shared blocks back on the grounds that deleting the last of them
        // releases the blocks — which the snapshot then goes on holding. Filing
        // them as unaccountable instead deducts those bytes rather than promising
        // them, which is the whole of what can honestly be said here.
        //
        // A read-only volume reports nothing shared either. Its files are not
        // unaccounted for, they are simply not deletable, and filing the sealed
        // system volume under "bytes nobody can explain" would be a scan-wide
        // warning about a disk behaving exactly as designed.
        let sharing: Sharing
        if kind != .file || reclaimable >= allocated || accounting == .readOnly {
            sharing = .none
        } else if sharesEverything, accounting != .pinned {
            sharing = .whole(familySize: Int(max(referenceCount, 1)), familyID: familyID)
        } else {
            sharing = .partial
        }

        let entry = Entry(kind: kind,
                          device: device,
                          inode: ino_t(fileID),
                          isCloudPlaceholder: flags & UInt32(SF_DATALESS) != 0,
                          isMountPoint: mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
                          logicalBytes: logical,
                          allocatedBytes: allocated,
                          reclaimableBytes: reclaimable,
                          sharing: sharing)
        let bytes = UnsafeRawBufferPointer(rebasing: raw[text ..< text + size - 1])
        return (length, Listing(name: String(decoding: bytes, as: UTF8.self), entry: entry))
    }

    public static func inspect(_ path: String) -> Entry? {
        var list = request()
        var buffer = [UInt8](repeating: 0, count: 512)
        let status = buffer.withUnsafeMutableBytes {
            getattrlist(path, &list, $0.baseAddress, $0.count, options)
        }
        guard status == 0 else { return nil }
        var info = stat()
        lstat(path, &info)
        return buffer.withUnsafeBytes { decode($0, at: 0, fallbackDevice: info.st_dev) }?.1.entry
    }

    /// Every entry in a directory, read in batches rather than one call per
    /// name. A home folder is millions of files, and the syscall per file is the
    /// scan; asking the kernel for a directory at a time is what turns minutes
    /// into seconds.
    public static func contents(of path: String) throws -> [Listing] {
        var found: [Listing] = []
        try stream(path) { found.append($0); return true }
        return found
    }

    /// Hands entries out in the batches the kernel returns them in, stopping
    /// when `body` returns false.
    ///
    /// A browser cache holds tens of thousands of files in one directory. A
    /// caller that only sees them once the last one is decoded cannot report
    /// progress or honour a cancel for as long as that read takes, and it
    /// holds the whole listing in memory to no purpose — on every walking
    /// thread at once.
    public static func stream(_ path: String, _ body: (Listing) -> Bool) throws {
        let directory = open(path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw ListingError.of(errno) }
        defer { close(directory) }

        var info = stat()
        fstat(directory, &info)

        var list = request()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(directory, &list, $0.baseAddress, $0.count, UInt64(options))
            }
            guard count > 0 else {
                // Classified the same way as the open, because this is where a
                // dataless directory actually fails: opening one succeeds, and
                // the kernel only discovers it needs the provider when it is
                // asked for the contents.
                guard count == 0 else { throw ListingError.of(errno) }
                return
            }
            var offset = 0
            for _ in 0 ..< count {
                guard let (length, listing) = buffer.withUnsafeBytes({
                    decode($0, at: offset, fallbackDevice: info.st_dev)
                }) else { throw ListingError.failed(EIO) }
                if !body(listing) { return }
                offset += length
            }
        }
    }
}

/// What deleting a whole selection would return to the volume.
///
/// Summing each file's own reclaimable size is a floor, not an answer: two
/// folders that are clones of each other each report zero, yet deleting both
/// frees the full amount. Summing allocated size is the opposite error and much
/// worse — it promises bytes that will not arrive.
///
/// The answer needs clone families. Every file that shares all of its blocks
/// carries a family id and a count of how many files are in that family, so a
/// selection holding the whole family gets the blocks and a selection holding
/// part of it gets nothing. What the count cannot see is a clone that was
/// written to afterwards: it keeps holding the family's untouched blocks but is
/// no longer counted among them. Those files are found during the scan, and
/// what they hold is deducted here rather than promised.
public enum SelectionSpace {
    public struct Estimate: Sendable {
        /// What will come free. Never optimistic.
        public let bytes: Int64
        /// How much of the selection is held by files that share blocks in a way
        /// APFS does not account for, and so could not be credited.
        public let unprovenBytes: Int64
    }

    /// - Parameter volumeUnproven: bytes held across the whole volume by files
    ///   whose sharing the reference count does not describe. Whatever part of
    ///   that lies outside the selection could be keeping the selection's blocks
    ///   alive, and there is no way to tell which, so all of it is deducted.
    public static func estimate(_ roots: [URL], volumeUnproven: Int64) -> Estimate {
        var exclusive: Int64 = 0
        var unprovenInside: Int64 = 0
        var families: [UInt64: (seen: Int, size: Int, bytes: Int64)] = [:]
        var counted = Set<Identity>()

        func walk(_ path: String, _ entry: FileSpace.Entry) {
            guard !entry.isCloudPlaceholder else { return }

            if entry.kind == .directory {
                guard let listed = try? FileSpace.contents(of: path) else { return }
                for child in listed {
                    walk((path as NSString).appendingPathComponent(child.name), child.entry)
                }
                return
            }
            guard entry.kind == .file,
                  counted.insert(Identity(device: entry.device, inode: entry.inode)).inserted
            else { return }

            exclusive += entry.reclaimableBytes
            let shared = entry.allocatedBytes - entry.reclaimableBytes
            switch entry.sharing {
            case .none:
                break
            case .partial:
                unprovenInside += shared
            case .whole(let size, let id):
                let family = families[id] ?? (0, size, 0)
                families[id] = (family.seen + 1, max(family.size, size), max(family.bytes, shared))
            }
        }
        for root in roots {
            guard let entry = FileSpace.inspect(root.path) else { continue }
            walk(root.path, entry)
        }

        var closed: Int64 = 0
        for family in families.values where family.seen >= family.size { closed += family.bytes }

        let unprovenOutside = max(0, volumeUnproven - unprovenInside)
        return Estimate(bytes: exclusive + max(0, closed - unprovenOutside),
                        unprovenBytes: unprovenInside)
    }

    /// A hard link is one file reachable by several names. Charging every name
    /// would invent space that deleting cannot deliver.
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }
}
