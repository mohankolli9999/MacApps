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
    t.expect(m.physicalBytes >= 30_000, "physical bytes at least logical")

    // A hardlink must not be double-counted.
    let link = root.appendingPathComponent("a-link.bin")
    try? FileManager.default.linkItem(at: a, to: link)

    guard let m2 = try? DiskScanner.measure(root) else {
        t.expect(false, "scanner handled hardlink")
        return
    }
    t.equal(m2.fileCount, 2, "hardlink is not counted as an extra file")
    t.equal(m2.physicalBytes, m.physicalBytes, "hardlink adds no physical bytes")

    // A missing path is an error, not a zero.
    let missing = root.appendingPathComponent("does-not-exist")
    var threw = false
    do { _ = try DiskScanner.measure(missing) } catch { threw = true }
    t.expect(threw, "missing path throws rather than reporting zero")
}
