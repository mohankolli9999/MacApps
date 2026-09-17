import Foundation
import ReclaimCore

/// APFS clones are the whole point of this file, and `clonefile(2)` is the only
/// way to make one on demand — `cp -c` produces something that reports itself
/// inconsistently, and a fixture that lies is worse than no fixture. Every clone
/// here is asserted to be a real one before anything is measured against it.
private func makeTree() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("filespace-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func writeFile(_ bytes: Int, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    // Incompressible, so decmpfs never quietly changes what is being measured.
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    try! data.write(to: url)
}

func clone(_ source: URL, to destination: URL) {
    try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let rc = source.withUnsafeFileSystemRepresentation { s in
        destination.withUnsafeFileSystemRepresentation { d in
            clonefile(s!, d!, 0)
        }
    }
    precondition(rc == 0, "clonefile failed: \(errno)")
}

/// A compressed file that SIP does not protect, on a writable volume.
///
/// Discovered rather than named. There is no API for compressing a file, so the
/// fixture has to be something already on the disk, and which of those exist
/// varies by machine. Naming one also conflates mechanisms: the obvious
/// candidate is a system binary, and those are compressed *and* SIP-restricted
/// *and* on a read-only snapshot mount, so a test pinned to one passes or fails
/// for three reasons at once.
func findCompressedFile() -> String? {
    let fm = FileManager.default
    for app in (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [] {
        for sub in ["Contents/MacOS", "Contents/Frameworks", "Contents/Resources"] {
            let directory = "/Applications/\(app)/\(sub)"
            for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
                let path = "\(directory)/\(name)"
                var info = stat()
                guard lstat(path, &info) == 0,
                      info.st_flags & UInt32(UF_COMPRESSED) != 0,
                      info.st_flags & UInt32(SF_RESTRICTED) == 0,
                      sharesAllBlocks(path) == false,
                      let entry = FileSpace.inspect(path),
                      entry.allocatedBytes > 0
                else { continue }
                return path
            }
        }
    }
    return nil
}

/// `EF_SHARES_ALL_BLOCKS`, read straight from the kernel rather than inferred
/// from what `FileSpace` reports.
///
/// Installers ship a good many application binaries pre-cloned, and one of those
/// is the wrong fixture for the substitution above — it correctly frees nothing.
/// Selecting on `Entry.sharing` would be circular, since a file the substitution
/// wrongly fired on reports `.none` and would be picked precisely when the test
/// most needed to fail.
func sharesAllBlocks(_ path: String) -> Bool {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = ATTR_CMN_RETURNED_ATTRS
    list.forkattr = attrgroup_t(0x0000_0200)
    var answer = (length: UInt32(0), returned: attribute_set_t(), flags: UInt64(0))
    let options = UInt32(FSOPT_NOFOLLOW) | 0x0000_0020 | 0x0000_0008
    guard getattrlist(path, &list, &answer, MemoryLayout.size(ofValue: answer), options) == 0
    else { return false }
    return answer.flags & 0x0000_0040 != 0
}

/// A resource fork is a second stream of bytes hanging off the same file, and
/// the only way to make one without a legacy API is to write to its magic path.
func writeResourceFork(_ bytes: Int, to url: URL) {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    try! data.write(to: url.appendingPathComponent("..namedfork/rsrc"))
}

/// Rewrites part of a clone in place, which is how a *partial* sharer comes
/// about: APFS un-shares the touched blocks, drops the file out of its clone
/// family, and stops counting it in the family's reference count — while it goes
/// on holding every block it did not touch.
func overwrite(_ url: URL, atOffset offset: Int, bytes: Int) {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    let handle = try! FileHandle(forWritingTo: url)
    try! handle.seek(toOffset: UInt64(offset))
    try! handle.write(contentsOf: data)
    try! handle.close()
}

@MainActor func runFileSpaceTests(_ t: Harness) {
    t.section("File space")

    // A file nobody shares with frees everything it occupies.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let solo = root.appendingPathComponent("solo.bin")
        writeFile(4 << 20, to: solo)

        let e = FileSpace.inspect(solo.path)!
        t.equal(e.kind, .file, "a regular file reads as one")
        t.equal(e.allocatedBytes, 4 << 20, "a lone file's allocation is its size")
        t.equal(e.reclaimableBytes, e.allocatedBytes, "deleting a lone file frees all of it")
        t.expect(e.sharing == .none, "a lone file shares with nobody")
        t.equal(e.logicalBytes, 4 << 20, "and the same read reports its logical size")
    }

    // The logical size is what the file claims to hold, which a sparse file
    // makes larger than anything it occupies. Reading both from one call is why
    // the scanner no longer needs a stat alongside the attribute read.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sparse = root.appendingPathComponent("sparse.bin")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: sparse)
        try! handle.truncate(atOffset: 64 << 20)
        try! handle.close()

        let e = FileSpace.inspect(sparse.path)!
        t.equal(e.logicalBytes, 64 << 20, "a sparse file's logical size is what it claims")
        t.expect(e.allocatedBytes < e.logicalBytes,
                 "while it occupies less than it claims")
    }

    // A clone frees nothing on its own, because the partner keeps the blocks.
    pair: do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        writeFile(4 << 20, to: a)
        clone(a, to: b)

        let ea = FileSpace.inspect(a.path)!
        let eb = FileSpace.inspect(b.path)!
        t.equal(ea.allocatedBytes, 4 << 20, "a clone still reports full allocation")
        t.equal(ea.reclaimableBytes, 0, "deleting one of two clones frees nothing")
        t.equal(eb.reclaimableBytes, 0, "and that holds for either side of the pair")

        guard case .whole(let size, let family) = ea.sharing else {
            t.expect(false, "a clone shares every block")
            break pair
        }
        t.equal(size, 2, "both members are counted in the family")
        t.expect(eb.sharing == .whole(familySize: 2, familyID: family),
                 "both sides name the same family")
    }

    // The case that broke the first design: a clone that was written to
    // afterwards. It goes on holding every block it did not touch, but APFS
    // un-shares the ones it did, drops it from the clone family, and gives it a
    // new family id — and does the same to the file it was cloned from.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let edited = root.appendingPathComponent("edited.bin")
        writeFile(4 << 20, to: source)
        clone(source, to: edited)
        overwrite(edited, atOffset: 1 << 20, bytes: 1 << 20)

        let after = FileSpace.inspect(edited.path)!
        t.expect(after.sharing == .partial, "a rewritten clone shares only some of its blocks")
        t.equal(after.allocatedBytes, 4 << 20, "it still occupies the whole file")
        t.equal(after.reclaimableBytes, 1 << 20, "only the rewritten megabyte is its own")

        // Both sides now report a family of one while three of their four
        // megabytes are still held by the other. Any accounting that trusts the
        // reference count to name every holder over-promises here.
        let origin = FileSpace.inspect(source.path)!
        t.expect(origin.sharing == .partial, "the file it was cloned from is left partly shared too")
        t.equal(origin.reclaimableBytes, 1 << 20,
                "and can only promise the megabyte it now owns alone")
    }

    // Directories, links and absences all have to answer without an lstat, since
    // this call is what replaces lstat in the scanner.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.bin")
        writeFile(1 << 20, to: file)
        let link = root.appendingPathComponent("link")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        t.equal(FileSpace.inspect(root.path)?.kind, .directory, "a directory reads as one")
        t.equal(FileSpace.inspect(link.path)?.kind, .other, "a symlink is not followed")
        t.expect(FileSpace.inspect(root.appendingPathComponent("gone").path) == nil,
                 "a path that is not there measures as nothing")

        var s = stat()
        lstat(file.path, &s)
        t.equal(FileSpace.inspect(file.path)?.inode, s.st_ino, "the inode matches lstat")
    }

    // A compressed file keeps its data outside the ordinary file extents, so it
    // reports real allocation against no private bytes and looks exactly like a
    // file a snapshot is holding. The allocated size is substituted for it, but
    // only in `exact` mode, which is what makes the two distinguishable: `exact`
    // means no snapshot on this volume, so the reading cannot have that cause.
    //
    // Worth the branch rather than under-reporting, because app bundles are
    // heavily compressed and the compressed file is usually the biggest binary
    // in the bundle. Measured over /Applications: 2,137 compressed files with no
    // sharing bits, 193 MiB, including a 24.8 MB main binary that would
    // otherwise tell the user deleting it frees nothing.
    //
    // The clone case is guarded by `sharesEverything` and cannot be covered here
    // without cloning one of the user's application binaries, which changes that
    // file's flags for as long as the copy exists. Measured by hand instead:
    // a compressed file at `ext 0x0` becomes `0x41` on both copies the moment it
    // is cloned, and drops back to the sticky `0x1` when the copy is deleted. So
    // the guard sees the clone, and the substitution does not double-promise.
    if let path = findCompressedFile() {
        defer { FileSpace.volumeAccounting = [:] }
        let e = FileSpace.inspect(path)!
        let device = e.device
        t.equal(e.reclaimableBytes, e.allocatedBytes,
                "a compressed file frees what it occupies")

        FileSpace.volumeAccounting[device] = .pinned
        if let pinned = FileSpace.inspect(path) {
            t.equal(pinned.reclaimableBytes, 0,
                    "and the substitution does not escape into a pinned volume")
        }
    }

    // The sealed system volume, which is the case the compressed test above used
    // to stand in for and should not have. Nothing here can be deleted at all,
    // so the honest reclaimable figure is zero regardless of what any file says
    // — and it is reached by asking the mount, not by reading the files. The
    // volume is also snapshot-mounted (`/dev/disk3s1s1`, where the second `s`
    // marks a snapshot) which zeroes every private size on it, but that snapshot
    // is not in the snapshot list, so detection would miss it. Read-only is what
    // makes this right rather than lucky.
    do {
        defer { FileSpace.volumeAccounting = [:] }
        let root = URL(fileURLWithPath: "/")
        FileSpace.record(volumeAt: root, snapshotted: false)
        let e = FileSpace.inspect("/bin/ls")
        t.expect(e != nil, "a system binary can be measured")
        if let e {
            t.expect(e.allocatedBytes > 0, "/bin/ls occupies blocks")
            t.equal(e.reclaimableBytes, 0, "and nothing on a read-only volume is reclaimable")
            t.equal(e.sharing, .none,
                    "which is not the same as its bytes being unaccounted for")
        }
    }

    // A file can hold bytes in a second stream, and the private size does not
    // count them — it measures the data fork alone. Nothing in the flags says
    // so: a file whose bytes are all in its resource fork carries no common
    // flags and no extended flags, and reads exactly like an ordinary file
    // whose blocks are shared. `ATTR_FILE_RSRCALLOCSIZE` is what tells them
    // apart, and it is why "the file has no sharing bits, so its allocated size
    // is its private size" is false.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        // Custom folder icons are the common case and the benign one: the data
        // fork is empty, so the private size is zero and the file falls into
        // the same branch as a compressed one, which happens to be right.
        let icon = root.appendingPathComponent("icon.bin")
        FileManager.default.createFile(atPath: icon.path, contents: nil)
        writeResourceFork(600 << 10, to: icon)
        if let e = FileSpace.inspect(icon.path) {
            t.equal(e.reclaimableBytes, e.allocatedBytes,
                    "a file that is nothing but a resource fork frees what it occupies")
            t.equal(e.sharing, .none, "and is not reported as sharing anything")
        }

        // Both forks populated is the case that was wrong: the private size is
        // the data fork, so the resource fork went uncounted and the shortfall
        // was read as evidence of sharing.
        let both = root.appendingPathComponent("both.bin")
        writeFile(800 << 10, to: both)
        writeResourceFork(300 << 10, to: both)
        if let e = FileSpace.inspect(both.path) {
            t.equal(e.reclaimableBytes, e.allocatedBytes,
                    "both forks are counted, because deleting the file frees both")
            t.equal(e.sharing, .none,
                    "a resource fork is not mistaken for unaccountable sharing")
        }

        // The guard rail on the fix. Cloning copies the resource fork too, and
        // its allocated size still reads full on both copies — so adding it
        // unconditionally would promise the same bytes twice.
        let clonedBoth = root.appendingPathComponent("both-clone.bin")
        clone(both, to: clonedBoth)
        if let e = FileSpace.inspect(clonedBoth.path) {
            t.equal(e.reclaimableBytes, 0,
                    "a cloned file frees nothing, resource fork included")
        }
    }

    // While a snapshot holds a volume's blocks, deleting a file older than it
    // frees nothing, and the kernel says so by reporting a private size of zero.
    // Measured on this machine: a 300 MB tree deleted under a snapshot returned
    // no free space at all, and the space only came back when the snapshot went.
    // Every rule that credits bytes the private size did not account for is
    // therefore wrong on such a volume — the unaccounted bytes are unaccounted
    // *because* they are pinned. A real snapshot cannot be taken from a test, so
    // the volume fact is injected and the rules are checked against it.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = FileSpace.inspect(root.path)!.device
        defer { FileSpace.volumeAccounting = [:] }

        let icon = root.appendingPathComponent("pinned-icon.bin")
        FileManager.default.createFile(atPath: icon.path, contents: nil)
        writeResourceFork(600 << 10, to: icon)
        let fresh = root.appendingPathComponent("pinned-plain.bin")
        writeFile(400 << 10, to: fresh)
        // Its own file to clone: cloning zeroes the private size of the original
        // as well as the copy, which would make `fresh` prove the wrong thing.
        let source = root.appendingPathComponent("pinned-source.bin")
        writeFile(400 << 10, to: source)
        let cloned = root.appendingPathComponent("pinned-clone.bin")
        clone(source, to: cloned)

        FileSpace.volumeAccounting[device] = .pinned
        if let e = FileSpace.inspect(icon.path) {
            t.equal(e.reclaimableBytes, 0,
                    "under a snapshot no byte is credited past the private size")
        }
        // The other half of the rule, and the reason it is not "report zero for
        // the whole volume": a file written after the snapshot was taken is not
        // in it, reports its full private size, and really would free that much.
        if let e = FileSpace.inspect(fresh.path) {
            t.equal(e.reclaimableBytes, e.allocatedBytes,
                    "a file the snapshot does not hold still frees what it occupies")
        }
        // Selecting every member of a clone family normally earns its shared
        // blocks back. Under a snapshot it must not, so the family is withheld.
        if let e = FileSpace.inspect(cloned.path) {
            t.equal(e.sharing, .partial,
                    "a pinned clone is unaccountable rather than a closable family")
        }

        FileSpace.volumeAccounting = [:]
        if let e = FileSpace.inspect(icon.path) {
            t.equal(e.reclaimableBytes, e.allocatedBytes,
                    "and the credit returns once no snapshot holds the volume")
        }
    }

    // A volume that cannot clone answers the fork attributes with zeroes meaning
    // "never heard of it". Believing them reports an external drive as holding
    // nothing worth deleting, so allocated size is used instead — safe precisely
    // because a volume with no clones has no shared blocks to over-promise.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = FileSpace.inspect(root.path)!.device
        defer { FileSpace.volumeAccounting = [:] }

        let file = root.appendingPathComponent("plain.bin")
        writeFile(700 << 10, to: file)
        let copy = root.appendingPathComponent("plain-clone.bin")
        clone(file, to: copy)

        FileSpace.volumeAccounting[device] = .allocation
        if let e = FileSpace.inspect(copy.path) {
            t.equal(e.reclaimableBytes, e.allocatedBytes,
                    "a volume with no clone support is read by what files occupy")
            t.equal(e.sharing, .none, "and nothing on it is reported as shared")
        }

        t.expect(FileSpace.clonesFiles(at: root.path),
                 "the volume this test runs on does clone, so the mode is chosen not guessed")
        t.expect(!FileSpace.clonesFiles(at: root.appendingPathComponent("gone").path),
                 "a path that is not there claims no capability")
    }

    // macOS firmlinks the Data volume into `/`, so `st_dev` is the same on both
    // sides and cannot bound a scan. The real device can.
    do {
        let system = FileSpace.inspect("/bin/ls")!
        let data = FileSpace.inspect(NSTemporaryDirectory())!
        t.expect(system.device != data.device,
                 "the system volume is a different device from the data volume")
    }

    // Reading a directory in batches is what separates a scan that finishes in
    // seconds from one that takes minutes, and the scanner uses both calls — the
    // batch for directories it lists, the single read for a root it is handed.
    // If the two ever disagreed about the same file the totals would depend on
    // how the file was reached.
    //
    // Worth knowing what this test cannot catch, because it was trusted for
    // that once. Both calls request the same attributes, so parity here only
    // proves the two decoders agree — it says nothing about whether the number
    // they agree on is right. An attempt to make the batch read cheaper by
    // dropping the private size passed this fixture cleanly and still
    // over-reported a real home folder by tens of megabytes. Sizing is checked
    // against known-size fixtures above; parity is checked here; neither
    // substitutes for the other.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let solo = root.appendingPathComponent("solo.bin")
        writeFile(4 << 20, to: solo)
        let a = root.appendingPathComponent("a.bin")
        writeFile(4 << 20, to: a)
        clone(a, to: root.appendingPathComponent("b.bin"))
        let edited = root.appendingPathComponent("edited.bin")
        clone(a, to: edited)
        overwrite(edited, atOffset: 1 << 20, bytes: 1 << 20)
        // One inode, two names. Hard links share the inode, not the blocks, so
        // each name reports the file's full private size — which is why the
        // scanner needs no link count to size one. Not double-counting it is a
        // separate problem, solved by the inode ledger rather than here.
        try! FileManager.default.linkItem(at: solo,
                                          to: root.appendingPathComponent("hardlink.bin"))
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                 withIntermediateDirectories: false)
        try! FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                    withDestinationURL: a)

        let listed = (try? FileSpace.contents(of: root.path)) ?? []
        t.equal(listed.map(\.name).sorted(),
                ["a.bin", "b.bin", "edited.bin", "hardlink.bin", "link", "solo.bin", "sub"],
                "a batch read returns every entry, named")

        var disagreements: [String] = []
        for entry in listed {
            let single = FileSpace.inspect(root.appendingPathComponent(entry.name).path)
            if single != entry.entry { disagreements.append(entry.name) }
        }
        t.equal(disagreements, [], "a batch read agrees with a single read, field for field")

        // The scanner keeps only what is on the volume it was pointed at, so an
        // entry with no device is an entry that quietly disappears from the
        // total. Nothing mounted has device zero.
        t.equal(listed.filter { $0.entry.device == 0 }.map(\.name), [],
                "every entry names the device its bytes are on")
    }

    // A browser cache holds tens of thousands of files in one directory, and
    // buffering the listing whole is what freezes a progress bar for as long
    // as the read takes: the caller's loop cannot start until the last entry
    // is decoded. Three thousand entries span several kernel batches, which is
    // the smallest fixture that can tell streaming from buffering.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0 ..< 3_000 {
            writeFile(1, to: root.appendingPathComponent("f\(index).bin"))
        }

        var streamed: [String] = []
        try! FileSpace.stream(root.path) { streamed.append($0.name); return true }
        t.equal(streamed.sorted(),
                ((try? FileSpace.contents(of: root.path)) ?? []).map(\.name).sorted(),
                "streaming visits exactly what buffering returns")

        var seen = 0
        try! FileSpace.stream(root.path) { _ in seen += 1; return false }
        t.equal(seen, 1, "a caller that stops after one entry is not handed the rest")
    }

    // Rendering a directory the process was refused as empty is the failure that
    // makes a disk tool untrustworthy: it reports space as reclaimed that was
    // never looked at. Refusal and absence have to arrive as different answers.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let locked = root.appendingPathComponent("locked")
        try! FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        writeFile(1 << 20, to: locked.appendingPathComponent("hidden.bin"))
        try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: locked.path)
        }

        do {
            _ = try FileSpace.contents(of: locked.path)
            t.expect(false, "a directory the process cannot read is an error")
        } catch {
            t.equal(error as? FileSpace.ListingError, .denied,
                    "a refused directory says it was refused")
        }
        do {
            _ = try FileSpace.contents(of: root.appendingPathComponent("gone").path)
            t.expect(false, "a directory that is not there is an error")
        } catch {
            t.equal(error as? FileSpace.ListingError, .missing,
                    "and absence is not mistaken for refusal")
        }

        t.equal(FileSpace.ListingError.of(EACCES), .denied, "EACCES is a refusal")
        t.equal(FileSpace.ListingError.of(EPERM), .denied, "so is EPERM")
        t.equal(FileSpace.ListingError.of(ENOENT), .missing, "ENOENT is absence")
        t.equal(FileSpace.ListingError.of(EIO), .failed(EIO), "anything else keeps its number")
        // A cloud provider's directory whose contents are on a server. The
        // process has forbidden materialising them, so the kernel cannot answer
        // without a round trip it is not allowed to make and says so with a
        // deadlock error. Reading that as a refusal reports the scan as blocked
        // when it in fact knew the answer: none of those bytes are on this disk.
        t.equal(FileSpace.ListingError.of(EDEADLK), .dataless,
                "a listing that would need the provider is not a refusal")

        t.equal(FileSpace.ListingError.denied.disposition, .unreadable,
                "a refused directory is bytes the scan could not see")
        t.equal(FileSpace.ListingError.failed(EIO).disposition, .unreadable,
                "and so is an unexplained failure")
        t.equal(FileSpace.ListingError.dataless.disposition, .elsewhere,
                "a dataless directory holds nothing here, which is an answer")
        t.equal(FileSpace.ListingError.missing.disposition, .vanished,
                "and one that went away has nothing to report")

        t.expect(FileSpace.ListingError.denied.isWorthAskingAgain,
                 "a refusal under load is worth one more ask")
        t.expect(FileSpace.ListingError.failed(EIO).isWorthAskingAgain,
                 "so is a failure with no better explanation")
        t.expect(!FileSpace.ListingError.dataless.isWorthAskingAgain,
                 "asking twice cannot move bytes that are on a server")
        t.expect(!FileSpace.ListingError.missing.isWorthAskingAgain,
                 "nor bring back a directory that is gone")
    }
}

@MainActor func runSelectionSpaceTests(_ t: Harness) {
    t.section("Selection space")

    // The floor and the truth agree when nothing is shared.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        writeFile(4 << 20, to: root.appendingPathComponent("one.bin"))
        writeFile(4 << 20, to: root.appendingPathComponent("two.bin"))

        t.equal(SelectionSpace.estimate([root], volumeUnproven: 0).bytes, 8 << 20,
                "unshared files add up")
    }

    // The case that made this necessary: two folders that are clones of each
    // other. Either alone frees nothing; together they free the full amount.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        writeFile(4 << 20, to: left.appendingPathComponent("data.bin"))
        clone(left.appendingPathComponent("data.bin"),
              to: right.appendingPathComponent("data.bin"))

        t.equal(SelectionSpace.estimate([left], volumeUnproven: 0).bytes, 0,
                "deleting one of two cloned folders frees nothing")
        t.equal(SelectionSpace.estimate([right], volumeUnproven: 0).bytes, 0,
                "nor does deleting the other")
        t.equal(SelectionSpace.estimate([left, right], volumeUnproven: 0).bytes, 4 << 20,
                "deleting both frees the blocks they were sharing")
    }

    // A third copy outside the selection keeps the blocks alive, so selecting
    // two of three must still report nothing.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        let c = root.appendingPathComponent("c.bin")
        writeFile(4 << 20, to: a)
        clone(a, to: b)
        clone(a, to: c)

        t.equal(SelectionSpace.estimate([a, b], volumeUnproven: 0).bytes, 0,
                "two of three clones free nothing while the third survives")
        t.equal(SelectionSpace.estimate([a, b, c], volumeUnproven: 0).bytes, 4 << 20,
                "all three together free the blocks")
    }

    // Mixed selection: the shared part and the private part must both land.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        let solo = root.appendingPathComponent("solo.bin")
        writeFile(4 << 20, to: a)
        clone(a, to: b)
        writeFile(2 << 20, to: solo)

        t.equal(SelectionSpace.estimate([a, b, solo], volumeUnproven: 0).bytes, 6 << 20,
                "a clone family plus an unshared file")
        t.equal(SelectionSpace.estimate([a, solo], volumeUnproven: 0).bytes, 2 << 20,
                "only the unshared file when the family is split")
    }

    // A rewritten clone inside the selection can only offer the blocks it owns
    // outright. The rest belong to a family that has stopped counting it.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let edited = root.appendingPathComponent("edited.bin")
        writeFile(4 << 20, to: source)
        clone(source, to: edited)
        overwrite(edited, atOffset: 1 << 20, bytes: 1 << 20)

        let e = SelectionSpace.estimate([edited], volumeUnproven: 0)
        t.equal(e.bytes, 1 << 20, "a rewritten clone offers only the blocks it rewrote")
        t.equal(e.unprovenBytes, 3 << 20, "and says how much it holds that it cannot promise")
    }

    // The regression this whole redesign exists for, measured against a real
    // free-space delta on a scratch volume: a clone family wholly inside the
    // selection whose blocks are *also* held by a rewritten clone outside it.
    // Crediting the family in full over-promises by exactly what the outsider
    // still holds, and the reference count gives no warning at all.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside")
        let outside = root.appendingPathComponent("outside")
        let a = inside.appendingPathComponent("trap.bin")
        let b = inside.appendingPathComponent("trap-copy.bin")
        writeFile(8 << 20, to: a)
        clone(a, to: b)
        writeFile(8 << 20, to: inside.appendingPathComponent("solo.bin"))

        let stranger = outside.appendingPathComponent("trap-edited.bin")
        clone(a, to: stranger)
        overwrite(stranger, atOffset: 6 << 20, bytes: 2 << 20)

        let held = FileSpace.inspect(stranger.path)!
        let unproven = held.allocatedBytes - held.reclaimableBytes
        t.equal(unproven, 6 << 20, "the outsider still holds six of the family's megabytes")

        t.equal(SelectionSpace.estimate([inside], volumeUnproven: unproven).bytes, 10 << 20,
                "a family held by a rewritten clone elsewhere cannot be credited in full")
        t.equal(SelectionSpace.estimate([inside], volumeUnproven: 0).bytes, 16 << 20,
                "with nothing outside holding them, the same blocks do come free")
    }
}

@MainActor func runCollectorTests(_ t: Harness) {
    t.section("Collector")

    func node(_ path: String, physical: Int64 = 1 << 20, free: Int64 = 1 << 20) -> StorageNode {
        StorageNode(url: URL(fileURLWithPath: path),
                    name: (path as NSString).lastPathComponent,
                    physicalBytes: physical,
                    reclaimableBytes: free,
                    isDirectory: true,
                    children: [],
                    unlistedBytes: 0)
    }

    let home = NSHomeDirectory()

    // The whole point of a tray: picks made in one folder outlive walking into
    // another. Per-directory selection made gathering from four places into four
    // separate deletes, each quoting its own number.
    do {
        var tray = Collector()
        tray.add(node("\(home)/Downloads/big.dmg"))
        tray.add(node("\(home)/Movies/old.mov"))
        t.equal(tray.count, 2, "picks from two different folders both stay")
        t.equal(tray.floorBytes, 2 << 20, "and the floor is the sum of what each frees alone")
    }

    do {
        var tray = Collector()
        let same = node("\(home)/Downloads/big.dmg")
        tray.add(same)
        tray.add(same)
        t.equal(tray.count, 1, "picking the same thing twice picks it once")
    }

    // An ancestor already carries its children's bytes. Holding both double-counts
    // the floor, and trashing the parent first leaves the child a path to nowhere.
    do {
        var tray = Collector()
        tray.add(node("\(home)/Downloads/archive", free: 8 << 20))
        tray.add(node("\(home)/Downloads/archive/big.dmg", free: 2 << 20))
        t.equal(tray.count, 1, "a child cannot join a tray that already holds its parent")
        t.equal(tray.floorBytes, 8 << 20, "so the parent's total is not counted twice")

        var other = Collector()
        other.add(node("\(home)/Downloads/archive/big.dmg", free: 2 << 20))
        other.add(node("\(home)/Downloads/archive", free: 8 << 20))
        t.equal(other.count, 1, "and adding the parent afterwards absorbs the child")
        t.equal(other.floorBytes, 8 << 20, "leaving the parent's total, not the sum")

        var sibling = Collector()
        sibling.add(node("\(home)/Downloads/one", free: 1 << 20))
        sibling.add(node("\(home)/Downloads/one-more", free: 1 << 20))
        t.equal(sibling.count, 2,
                "a name that merely starts with another's is not inside it")
    }

    // The tray is what the Trash button acts on, so anything the app must never
    // remove has to be refused at the door rather than filtered at the end.
    do {
        var tray = Collector()
        tray.add(node(home))
        tray.add(node("\(home)/Documents"))
        tray.add(node("/System/Library/Fonts"))
        tray.add(node("/Library/Caches"))
        t.expect(tray.isEmpty, "home, its fixtures, and anything outside your control stay out")

        t.expect(!Collector.admits(node("\(home)/Library")),
                 "a standard home folder is a fixture, not an item")
        t.expect(Collector.admits(node("\(home)/Library/Caches/pip")),
                 "something inside one is still fair game")
    }

    do {
        var tray = Collector()
        let pick = node("\(home)/Downloads/big.dmg")
        tray.add(pick)
        t.expect(tray.contains(pick.id), "what went in can be found by id")
        tray.remove(id: pick.id)
        t.expect(tray.isEmpty, "and taken back out again")
        t.equal(tray.floorBytes, 0, "with the number following it out")
    }

    do {
        var tray = Collector()
        tray.add(node("\(home)/Downloads/a", physical: 9 << 20, free: 1 << 20))
        t.equal(tray.physicalBytes, 9 << 20, "the tray knows what its picks occupy")
        t.equal(tray.floorBytes, 1 << 20, "as well as what removing them returns")
        tray.removeAll()
        t.expect(tray.isEmpty, "and it can be emptied in one go")
    }
}
