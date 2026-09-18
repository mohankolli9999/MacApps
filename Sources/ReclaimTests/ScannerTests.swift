import Foundation
import ReclaimCore

@MainActor func runScannerTests(_ t: Harness) {
    t.section("Scanner")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("reclaim-scan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let sub = root.appendingPathComponent("nested")
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

    let a = root.appendingPathComponent("a.bin")
    let b = sub.appendingPathComponent("b.bin")
    try? Data(repeating: 0x41, count: 10_000).write(to: a)
    try? Data(repeating: 0x42, count: 20_000).write(to: b)

    guard let m = try? DiskScanner.measure(root) else {
        t.expect(false, "scanner returned a measurement")
        return
    }
    t.equal(m.fileCount, 2, "counts files recursively")
    t.equal(m.logicalBytes, 30_000, "sums logical bytes")
    t.expect(m.reclaimableBytes >= 30_000, "unshared files return at least what they hold")

    // A hardlink must not be double-counted.
    let link = root.appendingPathComponent("a-link.bin")
    try? FileManager.default.linkItem(at: a, to: link)

    guard let m2 = try? DiskScanner.measure(root) else {
        t.expect(false, "scanner handled hardlink")
        return
    }
    t.equal(m2.fileCount, 2, "hardlink is not counted as an extra file")
    t.equal(m2.reclaimableBytes, m.reclaimableBytes, "hardlink adds no bytes")

    // A missing path is an error, not a zero.
    let missing = root.appendingPathComponent("does-not-exist")
    var threw = false
    do { _ = try DiskScanner.measure(missing) } catch { threw = true }
    t.expect(threw, "missing path throws rather than reporting zero")

    t.section("Scanner — clones")

    // The whole reason `st_blocks` had to go. Two clones each report their full
    // size to `stat`, so the old accounting promised back 8 MB where deleting
    // one of them returns nothing.
    let clones = FileManager.default.temporaryDirectory
        .appendingPathComponent("reclaim-clone-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: clones) }

    let original = clones.appendingPathComponent("original.bin")
    let copy = clones.appendingPathComponent("copy.bin")
    writeFile(4 * 1024 * 1024, to: original)
    clone(original, to: copy)

    guard let c = try? DiskScanner.measure(clones) else {
        t.expect(false, "scanner measured the clone pair")
        return
    }
    t.equal(c.fileCount, 2, "both clones are separate files")
    t.equal(c.logicalBytes, 8 * 1024 * 1024, "both still claim their full size")
    // A floor, and knowingly low here: the family is entirely inside the folder,
    // so deleting all of it does return 4 MB. `SelectionSpace` is what credits
    // that; a per-file sum cannot, and must never round the other way.
    t.equal(c.reclaimableBytes, 0, "no single clone owns a block it can hand back")

    // The control: same bytes, no sharing, so the floor is the whole answer.
    let solo = FileManager.default.temporaryDirectory
        .appendingPathComponent("reclaim-solo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: solo) }
    writeFile(4 * 1024 * 1024, to: solo.appendingPathComponent("only.bin"))

    guard let s = try? DiskScanner.measure(solo) else {
        t.expect(false, "scanner measured the unshared file")
        return
    }
    t.equal(s.reclaimableBytes, 4 * 1024 * 1024, "an unshared file returns all of it")
}
