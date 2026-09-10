import Foundation
import ReclaimCore

private func approx(_ a: Double, _ b: Double, _ tol: Double = 0.0001) -> Bool {
    abs(a - b) < tol
}

@MainActor func runTreemapTests(_ t: Harness) {
    t.section("Treemap layout")

    let box = TreemapBox(x: 0, y: 0, width: 600, height: 400)

    t.expect(Treemap.layout([], in: box).isEmpty, "no nodes lays out nothing")

    let single = Treemap.layout([TreemapNode(id: "a", value: 10)], in: box)
    t.equal(single.count, 1, "one node yields one rect")
    if let r = single.first {
        t.expect(approx(r.width, 600) && approx(r.height, 400), "one node fills the box")
        t.expect(approx(r.x, 0) && approx(r.y, 0), "one node starts at the origin")
    }

    let nodes = [
        TreemapNode(id: "ollama", value: 15.5),
        TreemapNode(id: "docker", value: 8.1),
        TreemapNode(id: "npm", value: 4.1),
        TreemapNode(id: "brew", value: 1.4),
        TreemapNode(id: "pip", value: 0.9),
        TreemapNode(id: "hf", value: 5.1),
    ]
    let rects = Treemap.layout(nodes, in: box)
    t.equal(rects.count, nodes.count, "every node gets a rect")

    // Area must be proportional to value: the whole point of a treemap.
    let total = nodes.reduce(0) { $0 + $1.value }
    let boxArea = box.width * box.height
    var areaOK = true
    for node in nodes {
        guard let r = rects.first(where: { $0.id == node.id }) else { areaOK = false; break }
        let expected = boxArea * (node.value / total)
        if !approx(r.width * r.height, expected, 0.5) { areaOK = false }
    }
    t.expect(areaOK, "each rect's area is proportional to its value")

    // Rects must tile the box: no gaps, no overlaps.
    let covered = rects.reduce(0.0) { $0 + $1.width * $1.height }
    t.expect(approx(covered, boxArea, 0.5), "rects cover the box exactly")

    var overlaps = false
    for i in rects.indices {
        for j in rects.indices where j > i {
            let a = rects[i], b = rects[j]
            let xOverlap = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
            let yOverlap = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
            if xOverlap > 0.0001 && yOverlap > 0.0001 { overlaps = true }
        }
    }
    t.expect(!overlaps, "no two rects overlap")

    var inside = true
    for r in rects where r.x < -0.0001 || r.y < -0.0001
        || r.x + r.width > box.width + 0.0001 || r.y + r.height > box.height + 0.0001 {
        _ = r
        inside = false
    }
    t.expect(inside, "every rect stays inside the box")

    // Squarified means usable aspect ratios. A naive slice-and-dice would
    // produce slivers here, which are unreadable and unclickable.
    let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
    t.expect(worst < 4.0, "worst aspect ratio stays under 4 (got \(String(format: "%.2f", worst)))")

    t.section("Treemap edge cases")

    let zeroed = Treemap.layout([TreemapNode(id: "a", value: 0),
                                 TreemapNode(id: "b", value: 0)], in: box)
    t.expect(zeroed.allSatisfy { $0.width >= 0 && $0.height >= 0 },
             "all-zero values produce no negative geometry")

    let mixed = Treemap.layout([TreemapNode(id: "big", value: 100),
                                TreemapNode(id: "zero", value: 0)], in: box)
    t.equal(mixed.count, 2, "zero-valued nodes are still returned")
    if let z = mixed.first(where: { $0.id == "zero" }) {
        t.expect(approx(z.width * z.height, 0, 0.5), "a zero value gets zero area")
    }

    let empty = Treemap.layout(nodes, in: TreemapBox(x: 0, y: 0, width: 0, height: 0))
    t.expect(empty.allSatisfy { $0.width == 0 && $0.height == 0 },
             "a zero-sized box produces zero-sized rects")

    // Ordering must be stable so blocks do not swap places between frames
    // while the scan is still revising sizes.
    let again = Treemap.layout(nodes, in: box)
    t.expect(again.map(\.id) == rects.map(\.id), "layout is deterministic")

    // An animating treemap tweens values every frame. If layout re-sorted by the
    // in-flight value, blocks would swap places mid-animation.
    let pinned = nodes.sorted { $0.value > $1.value }
    let midFlight = pinned.map { TreemapNode(id: $0.id, value: $0.value * ($0.id == "npm" ? 4 : 1)) }
    let held = Treemap.layout(midFlight, in: box, presorted: true)
    t.expect(held.map(\.id) == pinned.map(\.id),
             "presorted layout keeps the caller's order even when values overtake")
    let holdArea = held.reduce(0.0) { $0 + $1.width * $1.height }
    t.expect(approx(holdArea, boxArea, 0.5), "presorted layout still tiles the box exactly")
}
