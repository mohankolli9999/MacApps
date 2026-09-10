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
        case failed(Int32)
    }

    private static func request() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = ATTR_CMN_RETURNED_ATTRS
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        list.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        list.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
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
    /// five present whether or not the filesystem has heard of them, and both
    /// zero-fill the rest: reading unconditionally is then correct everywhere,
    /// and the zeros are interpreted below rather than believed. It does *not*
    /// reserve space for attributes that do not apply to the object at hand,
    /// which is why a directory has no allocated size and that one field still
    /// has to be read from the mask.
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

        // A private size of zero means the blocks are not in ordinary file
        // extents. That is true of a clone, but equally of a compressed file, of
        // a placeholder that still holds blocks, and of every file on a volume
        // that has no concept of sharing at all — where these attributes come
        // back zeroed and trusting them would report an entire external drive as
        // freeing nothing. Only the clone case means deleting frees nothing, and
        // `EF_SHARES_ALL_BLOCKS` is what separates them. Testing the weaker
        // `EF_MAY_SHARE_BLOCKS` instead would be wrong, because that bit is
        // sticky: it survives the deletion of the last partner.
        let sharesEverything = extendedFlags & EF_SHARES_ALL_BLOCKS != 0
        let reclaimable = privateBytes == 0 && allocated > 0 && !sharesEverything
            ? allocated
            : privateBytes

        let sharing: Sharing
        if kind != .file || reclaimable >= allocated {
            sharing = .none
        } else if sharesEverything {
            sharing = .whole(familySize: Int(max(referenceCount, 1)), familyID: familyID)
        } else {
            sharing = .partial
        }

        let entry = Entry(kind: kind,
                          device: realDevice != 0 ? dev_t(realDevice) : fallbackDevice,
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
        let directory = open(path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else {
            switch errno {
            case EACCES, EPERM: throw ListingError.denied
            case ENOENT: throw ListingError.missing
            default: throw ListingError.failed(errno)
            }
        }
        defer { close(directory) }

        var info = stat()
        fstat(directory, &info)

        var list = request()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var found: [Listing] = []
        while true {
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(directory, &list, $0.baseAddress, $0.count, UInt64(options))
            }
            guard count > 0 else {
                guard count == 0 else { throw ListingError.failed(errno) }
                return found
            }
            var offset = 0
            for _ in 0 ..< count {
                guard let (length, listing) = buffer.withUnsafeBytes({
                    decode($0, at: offset, fallbackDevice: info.st_dev)
                }) else { throw ListingError.failed(EIO) }
                found.append(listing)
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
