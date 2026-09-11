import Foundation
import ReclaimCore

private func makeTree() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("volumescan-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ bytes: Int, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try! Data(count: bytes).write(to: url)
}

/// A real device boundary inside a temp tree.
///
/// Nothing cheaper reproduces one: a firmlink reports the same `st_dev` on both
/// sides, which is the whole reason the scanner asks the filesystem which device
/// the bytes are really on, and only a genuine second filesystem exercises that.
/// Returns nil rather than trapping so a machine that cannot attach an image
/// reports one honest failure instead of a crash mid-suite.
private func mountImage(at mountpoint: URL, filesystem: String = "APFS") -> URL? {
    let image = FileManager.default.temporaryDirectory
        .appendingPathComponent("volumescan-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)

    func run(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    guard run(["create", "-size", "16m", "-fs", filesystem, "-volname", "ScanProbe",
               "-type", "SPARSE", image.path, "-quiet"]),
          run(["attach", image.path + ".sparseimage", "-mountpoint", mountpoint.path,
               "-nobrowse", "-quiet"])
    else { return nil }
    return image.appendingPathExtension("sparseimage")
}

private func unmount(_ mountpoint: URL, image: URL) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    task.arguments = ["detach", mountpoint.path, "-force", "-quiet"]
    try? task.run()
    task.waitUntilExit()
    try? FileManager.default.removeItem(at: image)
}

/// Collects callbacks that arrive from the scan's own threads.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VolumeScanner.Progress] = []
    func add(_ p: VolumeScanner.Progress) { lock.withLock { items.append(p) } }
    var all: [VolumeScanner.Progress] { lock.withLock { items } }
}

@MainActor func runConcurrentScanTests(_ t: Harness) async {
    t.section("Concurrent scan")

    // Branches are walked in parallel purely for speed, so the one thing that
    // must not change is the answer. Measuring it against the serial walk is
    // the only assertion that actually protects that.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Distinct branch totals: equal ones would tie in the sort, and the
        // order of a tie is not something either scanner promises.
        for (n, branch) in ["alpha", "beta", "gamma", "delta"].enumerated() {
            for i in 0..<3 {
                write(200_000 * (n + 1) + 40_000 * i,
                      to: root.appendingPathComponent("\(branch)/\(i).bin"))
            }
        }
        write(700_000, to: root.appendingPathComponent("loose.bin"))
        write(4_000, to: root.appendingPathComponent("tiny.bin"))

        let serial = try! VolumeScanner.scan(root, listThreshold: 500_000)
        let seen = Collector()
        let concurrent = try! await VolumeScanner.scanConcurrently(root, listThreshold: 500_000) {
            seen.add($0)
        }

        t.equal(concurrent.root.physicalBytes, serial.root.physicalBytes,
                "the parallel walk reaches the same total as the serial one")
        t.equal(concurrent.root.unlistedBytes, serial.root.unlistedBytes,
                "the same entries fall below the threshold")
        t.equal(concurrent.root.reclaimableBytes, serial.root.reclaimableBytes,
                "and agree on what deleting it would give back")
        t.equal(concurrent.unprovenBytes, serial.unprovenBytes,
                "and on how much of it cannot be accounted for")
        t.equal(concurrent.root.children.map(\.name), serial.root.children.map(\.name),
                "the same children in the same order")

        let updates = seen.all
        t.expect(!updates.isEmpty, "the partial tree is published while the scan runs")
        t.expect(updates.last?.measuring.isEmpty == true,
                 "nothing is still marked as measuring once the scan returns")
    }

    // Every branch that lands is announced. Parallelism that still only speaks
    // at the end buys speed and shows nothing for it.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for branch in ["one", "two", "three"] {
            write(200_000, to: root.appendingPathComponent("\(branch)/file.bin"))
        }

        let seen = Collector()
        _ = try! await VolumeScanner.scanConcurrently(root, listThreshold: 0) { seen.add($0) }

        t.expect(seen.all.contains { !$0.measuring.isEmpty },
                 "an update lands while branches are still being walked")
        t.expect(seen.all.count >= 5,
                 "one update to open with, one per branch as it lands, one to close")

        // Branches finish concurrently, so two can land between one update and
        // the next and no particular intermediate count is promised. What is
        // promised: the set only shrinks, and it reaches empty.
        let counting = seen.all.map(\.measuring.count)
        t.expect((counting.first ?? 0) > 0, "the first update has branches still to walk")
        t.equal(counting.last, 0, "the last update has none")
        t.expect(zip(counting, counting.dropFirst()).allSatisfy { $0 >= $1 },
                 "a branch already counted is never marked as measuring again")
    }

    do {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        var threw = false
        do { _ = try await VolumeScanner.scanConcurrently(missing) } catch { threw = true }
        t.expect(threw, "a missing root is still an error when scanned in parallel")
    }
}

/// A dataless directory cannot be created on demand — only a File Provider sets
/// `SF_DATALESS`, and `chflags` has no keyword for it. So these cover the
/// counting and the plumbing, which is where a miscount would hide, and the
/// flag itself is verified against a real cloud folder on the machine.
@MainActor func runCloudPlaceholderTests(_ t: Harness) async {
    t.section("Cloud placeholders")

    // Everything below proves the scan does not *miscount* placeholders. What
    // stops it downloading them is one process-wide syscall, and no fixture can
    // exercise that: SF_DATALESS needs root to set, so a test cannot make a real
    // placeholder to walk into. Reading the policy back is what is left — it
    // catches the regression that matters, a call that silently stops taking
    // effect. The detection path itself is covered only by real-machine runs.
    FileSpace.refuseToMaterialisePlaceholders()
    t.equal(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS),
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
            "the process refuses to fetch a placeholder's bytes")

    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        write(200_000, to: root.appendingPathComponent("a/file.bin"))
        write(200_000, to: root.appendingPathComponent("b/file.bin"))

        let serial = try! VolumeScanner.scan(root, listThreshold: 0)
        t.equal(serial.cloudOnlyLocations, 0, "an ordinary tree holds no cloud placeholders")

        let concurrent = try! await VolumeScanner.scanConcurrently(root, listThreshold: 0)
        t.equal(concurrent.cloudOnlyLocations, 0,
                "the parallel walk agrees there are none")
    }

    // The count rides the same path as the unreadable count, which is aggregated
    // out of every branch. A field that only ever reports the root's own tally
    // would pass the test above and still lose every real placeholder.
    do {
        let root = makeTree()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appendingPathComponent("a/locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        write(200_000, to: root.appendingPathComponent("a/locked/file.bin"))
        write(200_000, to: root.appendingPathComponent("b/file.bin"))
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: root.appendingPathComponent("a/locked").path)

        let concurrent = try! await VolumeScanner.scanConcurrently(root, listThreshold: 0)
        t.equal(concurrent.unreadableLocations, 1,
                "a branch's tally reaches the top of a parallel scan")
    }
}

@MainActor func runVolumeScanTests(_ t: Harness) {
    t.section("Volume scan")

    // A tree is only useful if the parent's number is the sum of what is under
    // it. Anything else and the treemap's areas are a lie.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        write(300_000, to: root.appendingPathComponent("a/one.bin"))
        write(300_000, to: root.appendingPathComponent("a/two.bin"))
        write(100_000, to: root.appendingPathComponent("b/three.bin"))

        let result = try! VolumeScanner.scan(root, listThreshold: 0)
        let childSum = result.root.children.reduce(Int64(0)) { $0 + $1.physicalBytes }
        t.equal(result.root.physicalBytes, childSum, "parent total equals the sum of its children")
        t.equal(result.root.children.count, 2, "both directories are listed")
        t.expect(result.root.children.first?.name == "a",
                 "children are ordered largest first")
    }

    // Small entries must still be counted somewhere. Dropping them would make
    // the parent's size disagree with the blocks the disk actually holds.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        write(3_000_000, to: root.appendingPathComponent("big.bin"))
        for i in 0..<5 { write(10_000, to: root.appendingPathComponent("small\(i).bin")) }

        let result = try! VolumeScanner.scan(root, listThreshold: 1_000_000)
        t.equal(result.root.children.count, 1, "only entries above the threshold are listed")
        t.expect(result.root.unlistedBytes > 0, "smaller entries are retained as unlisted bytes")

        let listed = result.root.children.reduce(Int64(0)) { $0 + $1.physicalBytes }
        t.equal(result.root.physicalBytes, listed + result.root.unlistedBytes,
                "listed plus unlisted accounts for the whole directory")
    }

    // Without Full Disk Access much of a real disk is unreadable. Reporting zero
    // for those would quietly understate usage, which is the one thing a disk
    // tool must never do.
    do {
        let root = makeTree()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        write(200_000, to: root.appendingPathComponent("open/file.bin"))
        write(200_000, to: root.appendingPathComponent("locked/file.bin"))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000],
                                               ofItemAtPath: root.appendingPathComponent("locked").path)

        let result = try! VolumeScanner.scan(root, listThreshold: 0)
        t.equal(result.unreadableLocations, 1, "a directory that cannot be read is counted")
        // A count tells someone bytes are missing and leaves them no way to find
        // out which bytes. Naming the place is the difference between a caveat
        // and something the user can act on.
        t.equal(result.unreadablePaths, [root.appendingPathComponent("locked").path],
                "and named, so the user can go and look at it")
    }

    // Clones and hard links are one allocation on disk. Counting them twice
    // would invent free space that reclaiming can never deliver.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a/file.bin")
        write(500_000, to: original)
        let link = root.appendingPathComponent("b/link.bin")
        try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! FileManager.default.linkItem(at: original, to: link)

        let result = try! VolumeScanner.scan(root, listThreshold: 0)
        let single = try! VolumeScanner.scan(root.appendingPathComponent("a"), listThreshold: 0)
        t.equal(result.root.physicalBytes, single.root.physicalBytes,
                "a hard link is counted once, not twice")
    }

    // A clone is a second inode over the same blocks, so the ledger lets both
    // through and the tree charges for both — correct for a treemap, which is
    // answering "how big is this folder", and wrong for the only question the
    // user acts on, which is "what do I get back". Both numbers have to travel.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        writeFile(4 << 20, to: a)
        clone(a, to: root.appendingPathComponent("b.bin"))
        writeFile(2 << 20, to: root.appendingPathComponent("solo.bin"))

        let result = try! VolumeScanner.scan(root, listThreshold: 0)
        t.equal(result.root.physicalBytes, 10 << 20, "the tree draws what the files occupy")
        t.equal(result.root.reclaimableBytes, 2 << 20,
                "but only the unshared file frees anything on its own")
        t.equal(result.root.children.first { $0.name == "a.bin" }?.reclaimableBytes, 0,
                "either clone alone frees nothing")

        let sum = result.root.children.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        t.equal(result.root.reclaimableBytes, sum, "a parent frees what its children free")
    }

    // A clone that was written to afterwards holds blocks that no reference
    // count names. The scan is the only place that population can be found, so
    // it has to come back with the total rather than leave the estimate to guess.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let edited = root.appendingPathComponent("edited.bin")
        writeFile(4 << 20, to: source)
        clone(source, to: edited)
        overwrite(edited, atOffset: 1 << 20, bytes: 1 << 20)

        let result = try! VolumeScanner.scan(root, listThreshold: 0)
        t.equal(result.unprovenBytes, 6 << 20,
                "both sides of a broken clone report what they hold unaccountably")
        t.equal(result.root.reclaimableBytes, 2 << 20,
                "and each can still promise the megabyte it owns outright")
    }

    // Removing an entry has to correct both numbers, or the readout drifts every
    // time something goes to the Trash.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        writeFile(4 << 20, to: root.appendingPathComponent("gone.bin"))
        writeFile(2 << 20, to: root.appendingPathComponent("stays.bin"))

        let tree = try! VolumeScanner.scan(root, listThreshold: 0).root
        let gone = tree.children.first { $0.name == "gone.bin" }!
        let pruned = tree.removing([gone.id])
        t.equal(pruned.physicalBytes, 2 << 20, "the tree shrinks by what left it")
        t.equal(pruned.reclaimableBytes, 2 << 20, "and so does what it can free")
    }

    // macOS firmlinks the Data volume into /, so a scan of / meets every user
    // file twice — once at /Users and once at /System/Volumes/Data/Users. Inode
    // dedup keeps the bytes honest but the second walk is pure wasted minutes.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        write(400_000, to: root.appendingPathComponent("keep/file.bin"))
        write(400_000, to: root.appendingPathComponent("mirror/file.bin"))

        let skipped = root.appendingPathComponent("mirror")
        let result = try! VolumeScanner.scan(root, listThreshold: 0, skipping: [skipped.path])
        t.equal(result.root.children.count, 1, "a skipped directory is not walked")
        t.expect(result.root.children.first?.name == "keep", "the rest of the tree is unaffected")

        let whole = try! VolumeScanner.scan(root, listThreshold: 0)
        t.expect(result.root.physicalBytes < whole.root.physicalBytes,
                 "skipping removes those bytes from the total rather than hiding them")
    }

    // Branches are walked concurrently so a 170 GB home lands in seconds rather
    // than minutes. Each walk keeping its own record of what it has seen would
    // charge a file linked into two branches twice, which is the one arithmetic
    // error a disk tool cannot afford — so the record is shared.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a/file.bin")
        write(500_000, to: original)
        let link = root.appendingPathComponent("b/link.bin")
        try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! FileManager.default.linkItem(at: original, to: link)

        let ledger = InodeLedger()
        let a = try! VolumeScanner.scan(root.appendingPathComponent("a"),
                                        listThreshold: 0, ledger: ledger)
        let b = try! VolumeScanner.scan(root.appendingPathComponent("b"),
                                        listThreshold: 0, ledger: ledger)
        t.expect(a.root.physicalBytes > 0, "the first branch to reach the file is charged for it")
        t.equal(b.root.physicalBytes, 0, "the second branch is not charged again")

        let separate = try! VolumeScanner.scan(root.appendingPathComponent("b"), listThreshold: 0)
        t.expect(separate.root.physicalBytes > 0,
                 "a scan with its own ledger still counts what it finds")
    }

    // A whole-disk scan runs for minutes, so progress is the only thing telling
    // the user it is alive. It has to count the whole walk, not the directory it
    // happens to be standing in, or the readout slides backwards on the way out
    // of every subtree.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<12 { write(80_000, to: root.appendingPathComponent("deep/\(i)/file.bin")) }
        write(80_000, to: root.appendingPathComponent("shallow.bin"))

        var ticks: [VolumeScanner.Tick] = []
        let result = try! VolumeScanner.scan(root, listThreshold: 0, progressInterval: 0) {
            ticks.append($0)
        }

        t.expect(!ticks.isEmpty, "the scan reports progress")
        t.expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0.bytes <= $1.bytes },
                 "progress never goes backwards")
        t.equal(ticks.last?.bytes, result.root.physicalBytes,
                "progress finishes on the number the scan returns")
        t.expect(ticks.contains { $0.location.contains("deep") },
                 "progress names where the scan currently is")
    }

    // Once something is in the Trash the map has to agree with the disk at once.
    // Rescanning a 250 GB home to learn a number we already know is not an
    // option, so the tree is edited in place and the arithmetic has to hold.
    do {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        write(400_000, to: root.appendingPathComponent("a/one.bin"))
        write(200_000, to: root.appendingPathComponent("a/two.bin"))
        write(100_000, to: root.appendingPathComponent("b/three.bin"))

        let tree = try! VolumeScanner.scan(root, listThreshold: 0).root
        let a = tree.children.first { $0.name == "a" }!
        let one = a.children.first { $0.name == "one.bin" }!

        let pruned = tree.removing([one.id])
        t.equal(pruned.physicalBytes, tree.physicalBytes - one.physicalBytes,
                "the tree shrinks by exactly what left it")
        let prunedA = pruned.children.first { $0.name == "a" }!
        t.equal(prunedA.children.count, 1, "the removed entry is gone from its parent")
        t.equal(prunedA.physicalBytes, a.physicalBytes - one.physicalBytes,
                "every ancestor shrinks, not just the root")

        let withoutB = tree.removing([tree.children.first { $0.name == "b" }!.id])
        t.equal(withoutB.children.count, 1, "removing a directory takes its whole subtree")
    }

    do {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString)")
        var threw = false
        do { _ = try VolumeScanner.scan(missing) } catch { threw = true }
        t.expect(threw, "scanning a path that does not exist is an error, not an empty tree")
    }
}

@MainActor func runOffVolumeTests(_ t: Harness) async {
    t.section("Volume scan — crossings off the volume")

    // A mounted image is another disk and the scan stops at it, which is right:
    // following it would walk a network share and charge its bytes to this
    // volume. What is wrong is doing it silently, because a folder that could
    // not be counted then renders identically to one that was empty.
    //
    // A firmlink is the other case and is *not* covered here — see
    // `runFirmlinkTests`, which pins why this test's mechanism cannot detect one.
    let root = makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    write(2 << 20, to: root.appendingPathComponent("here.bin"))

    let mountpoint = root.appendingPathComponent("elsewhere")
    guard let image = mountImage(at: mountpoint) else {
        t.expect(false, "test fixture: could not attach a disk image to cross a volume boundary")
        return
    }
    defer { unmount(mountpoint, image: image) }
    write(3 << 20, to: mountpoint.appendingPathComponent("there.bin"))

    let result = try! VolumeScanner.scan(root, listThreshold: 0)
    t.equal(result.root.physicalBytes, 2 << 20, "bytes on another volume are not counted here")
    t.equal(result.offVolumeLocations, 1, "and the crossing is reported rather than dropped")
    t.equal(result.offVolumePaths, [mountpoint.path], "by name, not just as a tally")

    let clean = try! VolumeScanner.scan(root, listThreshold: 0, skipping: [mountpoint.path])
    t.equal(clean.offVolumeLocations, 0,
            "a crossing the caller already knows about is not a surprise")

    // The parallel walk meets the boundary in a different place — the root loop
    // that splits the branches — so it needs its own evidence, not an inference
    // from the serial one. It used to report 5 MB here: each branch re-derives
    // its bound from its own root, and probing a mount point resolves through
    // the mount where the bulk read that found it does not.
    let parallel = try! await VolumeScanner.scanConcurrently(root, listThreshold: 0)
    t.equal(parallel.root.physicalBytes, 2 << 20, "splitting the walk does not cross the boundary")
    t.equal(parallel.offVolumeLocations, 1, "the parallel walk reports the same crossing")

    let deep = makeTree()
    defer { try? FileManager.default.removeItem(at: deep) }
    write(1 << 20, to: deep.appendingPathComponent("branch/file.bin"))
    let buried = deep.appendingPathComponent("branch/nested/mount")
    guard let deepImage = mountImage(at: buried) else {
        t.expect(false, "test fixture: could not attach a second disk image")
        return
    }
    defer { unmount(buried, image: deepImage) }

    let nested = try! await VolumeScanner.scanConcurrently(deep, listThreshold: 0)
    t.equal(nested.offVolumeLocations, 1, "a crossing found inside a branch reaches the top")
}

/// A firmlink cannot be built in a fixture — only the OS installer makes them —
/// so this pins the kernel behaviour the scanner's detection is built on instead
/// of the scanner's arithmetic. If Apple ever teaches `getattrlistbulk` to
/// resolve firmlinks, the first two expectations fail and the extra `getattrlist`
/// per directory can be deleted.
@MainActor func runFirmlinkTests(_ t: Harness) {
    t.section("Volume scan — firmlink crossings")

    let fm = FileManager.default
    guard fm.fileExists(atPath: "/System/Volumes/Data"),
          let systemRoot = FileSpace.inspect("/"),
          let users = FileSpace.inspect("/Users") else {
        t.expect(false, "test fixture: no firmlinked Data volume to read")
        return
    }

    t.expect(users.device != systemRoot.device,
             "/Users resolves to a different volume than /")

    let listed = (try? FileSpace.contents(of: "/"))?.first { $0.name == "Users" }
    guard let listed else {
        t.expect(false, "test fixture: / does not list Users")
        return
    }
    // The whole reason the scanner spends a syscall per directory. A bulk read
    // describes the stub as it sits in its parent, so both sides of a firmlink
    // report the parent's volume and no comparison against that value can fire.
    t.equal(listed.entry.device, systemRoot.device,
            "a bulk read cannot see through the firmlink and reports / instead")
    t.expect(listed.entry.device != users.device,
             "which is precisely the value a device test must not trust")
    t.expect(!listed.entry.isMountPoint,
             "and a firmlink is not a mount point, so that test does not catch it either")
}

/// A symlink onto another volume must not read as a crossing.
///
/// This one *is* buildable in a fixture, and it guards the failure mode a
/// firmlink test cannot reach: resolve a symlink while looking for a crossing
/// and the walk follows it, charging another volume's bytes to this tree — the
/// exact double-count the counter exists to prevent.
@MainActor func runSymlinkCrossingTests(_ t: Harness) {
    t.section("Volume scan — symlinks are not crossings")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("symcross-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try! Data(count: 64 << 10).write(to: root.appendingPathComponent("local.bin"))

    // The sealed system volume is a real, guaranteed-present device boundary,
    // and unlike a mounted image it costs nothing to reach.
    let elsewhere = "/System/Library/CoreServices"
    guard let target = FileSpace.inspect(elsewhere),
          let here = FileSpace.inspect(root.path),
          target.device != here.device else {
        t.expect(false, "test fixture: no second volume to point a symlink at")
        return
    }
    try! FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                                withDestinationPath: elsewhere)

    let result = try! VolumeScanner.scan(root, listThreshold: 0)
    t.equal(result.firmlinkCrossings, 0, "a symlink onto another volume is not a crossing")
    t.equal(result.root.physicalBytes, 64 << 10,
            "and none of the volume it points at is charged to this tree")
}

/// A volume that has never heard of block sharing.
///
/// Every file on one reports a private size of zero while the returned mask says
/// the attribute is present and valid, so nothing in the reply separates "these
/// blocks are shared with someone" from "this filesystem does not have the
/// concept". `EF_SHARES_ALL_BLOCKS` is what separates them, and it is clear here
/// and set on a real clone. Reading that zero literally reports an entire
/// external drive as freeing nothing.
///
/// Two things are being held down, and the second is the reason this needs a
/// filesystem rather than a file. `EF_SHARES_ALL_BLOCKS` is also covered by a
/// compressed binary on APFS. `FSOPT_PACK_INVAL_ATTRS` is not covered anywhere
/// else: it changes nothing on APFS, so every other test in the suite passes
/// without it, and dropping it slides the decode cursor so that a file's private
/// size reads as the device id. Both branches have zero incidence on an
/// all-APFS machine, which is exactly what makes them look removable.
@MainActor func runNoCloneSupportTests(_ t: Harness) {
    t.section("Volume scan — filesystems without clones")

    let mountpoint = FileManager.default.temporaryDirectory
        .appendingPathComponent("noclone-\(UUID().uuidString)")
    guard let image = mountImage(at: mountpoint, filesystem: "HFS+") else {
        t.expect(false, "test fixture: no HFS+ image could be attached")
        return
    }
    defer {
        unmount(mountpoint, image: image)
        try? FileManager.default.removeItem(at: mountpoint)
    }

    let file = mountpoint.appendingPathComponent("sample.bin")
    write(64 << 10, to: file)
    guard let entry = FileSpace.inspect(file.path) else {
        t.expect(false, "a file on the image can be measured")
        return
    }

    t.equal(entry.allocatedBytes, 64 << 10, "the file occupies the blocks it was given")
    t.equal(entry.reclaimableBytes, 64 << 10,
            "and deleting it frees them, on a volume where nothing can be shared")
    // Spelled out because `.none` against an optional means nil, not this case.
    t.expect(entry.sharing == FileSpace.Sharing.none,
             "a private size of zero here is absence of the feature, not evidence of a clone")

    let result = try! VolumeScanner.scan(mountpoint, listThreshold: 0)
    t.equal(result.root.reclaimableBytes, 64 << 10,
            "so the volume does not report as freeing nothing")
    t.equal(result.unprovenBytes, 0, "and none of its bytes go unaccounted for")
}
