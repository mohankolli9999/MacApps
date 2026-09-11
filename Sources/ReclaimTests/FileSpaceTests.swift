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

    // Compressed files report no private bytes while holding real ones. Trusting
    // that zero would hide every system binary from the total.
    do {
        let e = FileSpace.inspect("/bin/ls")
        t.expect(e != nil, "a system binary can be measured")
        if let e {
            t.expect(e.allocatedBytes > 0, "/bin/ls occupies blocks")
            t.equal(e.reclaimableBytes, e.allocatedBytes,
                    "a compressed file is not mistaken for a clone")
        }
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
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        writeFile(4 << 20, to: root.appendingPathComponent("solo.bin"))
        let a = root.appendingPathComponent("a.bin")
        writeFile(4 << 20, to: a)
        clone(a, to: root.appendingPathComponent("b.bin"))
        let edited = root.appendingPathComponent("edited.bin")
        clone(a, to: edited)
        overwrite(edited, atOffset: 1 << 20, bytes: 1 << 20)
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                 withIntermediateDirectories: false)
        try! FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                    withDestinationURL: a)

        let listed = (try? FileSpace.contents(of: root.path)) ?? []
        t.equal(listed.map(\.name).sorted(),
                ["a.bin", "b.bin", "edited.bin", "link", "solo.bin", "sub"],
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
