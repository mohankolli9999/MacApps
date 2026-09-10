import Foundation
import ReclaimCore

@MainActor func runStreamingScanTests(_ t: Harness) {
    t.section("Streaming scan")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString)")
    for bucket in 0..<5 {
        let dir = root.appendingPathComponent("d\(bucket)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in 0..<40 {
            try? Data(repeating: 0x2A, count: 128).write(to: dir.appendingPathComponent("f\(file)"))
        }
    }
    defer { try? fm.removeItem(at: root) }

    let plain = try? DiskScanner.measure(root)
    t.equal(plain?.fileCount, 200, "fixture has 200 files")

    var updates: [DiskScanner.Measurement] = []
    let streamed = try? DiskScanner.measure(root, progressInterval: 0) { updates.append($0) }

    t.equal(streamed, plain, "streaming produces the same total as a plain measure")
    t.expect(updates.count > 1, "progress is reported more than once (got \(updates.count))")
    t.expect(updates.map(\.fileCount) == updates.map(\.fileCount).sorted(),
             "reported file counts only ever increase")
    if let last = updates.last, let plain {
        t.expect(last.reclaimableBytes <= plain.reclaimableBytes, "no progress overshoots the total")
    }

    // Throttling is what keeps the UI cheap: a 200k-file cache must not push
    // 200k updates at the main actor.
    var throttled = 0
    _ = try? DiskScanner.measure(root, progressInterval: 60) { _ in throttled += 1 }
    t.expect(throttled <= 1, "a long interval collapses progress to at most one update")

    t.section("Streaming scan cancellation")

    var seen = 0
    let partial = try? DiskScanner.measure(root, progressInterval: 0,
                                           onProgress: { _ in seen += 1 },
                                           isCancelled: { seen >= 20 })
    t.expect((partial?.fileCount ?? 999) < 200, "cancelling stops the walk early")
    t.expect((partial?.fileCount ?? 0) > 0, "a cancelled walk still returns what it counted")

    t.section("Streaming scan errors")

    let missing = root.appendingPathComponent("does-not-exist")
    var fired = false
    let failed = try? DiskScanner.measure(missing, progressInterval: 0) { _ in fired = true }
    t.expect(failed == nil, "a missing path still throws")
    t.expect(!fired, "a missing path reports no progress")
}
