import Foundation

public struct TreemapNode: Sendable, Equatable {
    public var id: String
    public var value: Double

    public init(id: String, value: Double) {
        self.id = id
        self.value = value
    }
}

public struct TreemapBox: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TreemapRect: Sendable, Equatable {
    public var id: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
///
/// Slice-and-dice is simpler but degenerates into slivers as soon as one value
/// dominates, and a 600x3 sliver is neither readable nor clickable. Squarifying
/// keeps aspect ratios near 1 so every block stays a usable target.
public enum Treemap {
    /// Pass `presorted` when the caller has already chosen an order and needs it
    /// kept. An animating treemap needs this: ordering by the value currently
    /// being tweened makes blocks trade places mid-flight, so callers order by
    /// the settled size once and animate within that fixed arrangement.
    public static func layout(_ nodes: [TreemapNode],
                              in box: TreemapBox,
                              presorted: Bool = false) -> [TreemapRect] {
        guard !nodes.isEmpty else { return [] }

        let ordered = presorted ? nodes : nodes.sorted {
            $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value
        }
        let zeroRect = { (n: TreemapNode) in
            TreemapRect(id: n.id, x: box.x, y: box.y, width: 0, height: 0)
        }

        guard box.width > 0, box.height > 0 else { return ordered.map(zeroRect) }

        // Zero-valued nodes are separated out rather than laid out: a zero-area
        // row has zero thickness, which would never shrink the free rect and
        // would spin the loop forever.
        let sized = ordered.filter { $0.value > 0 }
        let empties = ordered.filter { $0.value <= 0 }.map(zeroRect)
        guard !sized.isEmpty else { return empties }

        let totalValue = sized.reduce(0) { $0 + $1.value }
        let scale = (box.width * box.height) / totalValue
        let areas = sized.map { $0.value * scale }

        var result: [TreemapRect] = []
        var free = box
        var i = 0

        while i < areas.count {
            let side = min(free.width, free.height)

            // Grow the row while squareness improves.
            var end = i
            var sum = 0.0
            var lo = Double.infinity
            var hi = 0.0
            var bestRatio = Double.infinity

            while end < areas.count {
                let area = areas[end]
                let nextSum = sum + area
                let ratio = worstRatio(min(lo, area), max(hi, area), nextSum, side)
                if end > i && ratio > bestRatio { break }
                sum = nextSum
                lo = min(lo, area)
                hi = max(hi, area)
                bestRatio = ratio
                end += 1
            }

            let isLastRow = end == areas.count
            let horizontal = free.width <= free.height
            // The final row takes the whole remainder, so rounding never leaves a seam.
            var thickness = sum / side
            if isLastRow { thickness = horizontal ? free.height : free.width }

            var offset = 0.0
            for k in i..<end {
                let isLastInRow = k == end - 1
                var extent = sum > 0 ? (areas[k] / sum) * side : 0
                if isLastInRow { extent = max(0, side - offset) }

                result.append(horizontal
                    ? TreemapRect(id: sized[k].id, x: free.x + offset, y: free.y,
                                  width: extent, height: thickness)
                    : TreemapRect(id: sized[k].id, x: free.x, y: free.y + offset,
                                  width: thickness, height: extent))
                offset += extent
            }

            if horizontal {
                free.y += thickness
                free.height = max(0, free.height - thickness)
            } else {
                free.x += thickness
                free.width = max(0, free.width - thickness)
            }
            i = end
        }

        return result + empties
    }

    /// Worst aspect ratio in a row of the given areas laid across `side`.
    private static func worstRatio(_ lo: Double, _ hi: Double, _ sum: Double, _ side: Double) -> Double {
        guard sum > 0, side > 0, lo > 0 else { return .infinity }
        let s2 = sum * sum
        let w2 = side * side
        return max(w2 * hi / s2, s2 / (w2 * lo))
    }
}
