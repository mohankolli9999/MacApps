import SwiftUI
import ReclaimCore

/// Holds the tweened sizes between frames.
///
/// Deliberately not `@Observable`: the redraw is driven by `TimelineView`, so
/// mutating this during a draw must not invalidate the view that is drawing it.
@MainActor
final class TreemapAnimator {
    private var display: [String: Double] = [:]
    private var lastTick: Date?
    private(set) var rects: [TreemapRect] = []

    func advance(to date: Date, targets: [TreemapNode], box: TreemapBox, snap: Bool) -> [TreemapRect] {
        // Clamp dt so a backgrounded window does not teleport everything on return.
        let dt = min(lastTick.map { date.timeIntervalSince($0) } ?? 0, 0.1)
        lastTick = date

        let live = Set(targets.map(\.id))
        display = display.filter { live.contains($0.key) }

        // Exponential smoothing, so a 60Hz and a 120Hz display settle in the same
        // wall-clock time instead of the faster one racing ahead.
        let alpha = snap ? 1 : 1 - exp(-9.0 * dt)
        let tweened = targets.map { target -> TreemapNode in
            let current = display[target.id] ?? 0
            let next = current + (target.value - current) * alpha
            display[target.id] = next
            return TreemapNode(id: target.id, value: max(0, next))
        }

        rects = Treemap.layout(tweened, in: box, presorted: true)
        return rects
    }

    func hit(_ point: CGPoint) -> String? {
        rects.first {
            point.x >= $0.x && point.x <= $0.x + $0.width &&
            point.y >= $0.y && point.y <= $0.y + $0.height
        }?.id
    }
}

struct TreemapView: View {
    let rows: [ScanModel.Row]
    @Binding var selection: String?
    let paused: Bool
    let emptyMessage: String

    @State private var animator = TreemapAnimator()
    @State private var hovered: String?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pinned to settled size, so blocks keep their arrangement while tweening.
    private var targets: [TreemapNode] {
        rows.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
            .map { TreemapNode(id: $0.id, value: Double($0.reclaimableBytes)) }
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: paused)) { timeline in
                Canvas(rendersAsynchronously: false) { context, size in
                    let box = TreemapBox(x: 0, y: 0, width: size.width, height: size.height)
                    let laid = animator.advance(to: timeline.date, targets: targets,
                                                box: box, snap: reduceMotion)
                    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                    for rect in laid {
                        guard let row = byID[rect.id] else { continue }
                        draw(row, in: rect, context: &context)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let hit = animator.hit(tap.location)
                selection = (hit == selection) ? nil : hit
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = animator.hit(point)
                case .ended: hovered = nil
                }
            }
            .focusable(!rows.isEmpty)
            .focused($focused)
            .onMoveCommand(perform: step)
            .onExitCommand { selection = nil }
            .accessibilityLabel("Cache blocks, largest first")
        }
        .background(Theme.stage)
        .overlay {
            // A canvas has no focus ring of its own, and a keyboard user needs to
            // know which of the two maps the arrow keys are about to move inside.
            if focused {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .center) {
            if rows.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    /// Walks the blocks in size order rather than by geometry. A squarified
    /// layout has no stable grid to navigate spatially, and "next biggest" is
    /// the order the eye is already reading in.
    private func step(_ direction: MoveCommandDirection) {
        let ordered = rows.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        guard !ordered.isEmpty else { return }
        guard let current = selection,
              let i = ordered.firstIndex(where: { $0.id == current }) else {
            selection = ordered[0].id
            return
        }
        let forward = direction == .right || direction == .down
        selection = ordered[(i + (forward ? 1 : -1) + ordered.count) % ordered.count].id
    }

    private func draw(_ row: ScanModel.Row, in rect: TreemapRect, context: inout GraphicsContext) {
        let gutter = 1.5
        let frame = CGRect(x: rect.x + gutter, y: rect.y + gutter,
                           width: max(0, rect.width - gutter * 2),
                           height: max(0, rect.height - gutter * 2))
        guard frame.width > 1, frame.height > 1 else { return }

        let shape = Path(roundedRect: frame, cornerRadius: min(4, frame.height / 3))
        let hue = Theme.hue(for: row.id)
        context.fill(shape, with: .color(hue.opacity(Theme.fillOpacity(for: row.tier))))

        switch row.tier {
        case .irreplaceable, .unknown:
            // Texture, not just colour, so "you cannot get this back" survives
            // greyscale and colourblindness.
            hatch(frame, shape, hue, &context)
        case .costly:
            context.stroke(shape, with: .color(hue.opacity(0.9)), lineWidth: 1)
        case .exact:
            break
        }

        if selection == row.id {
            context.stroke(shape, with: .color(Theme.ink), lineWidth: 2)
        } else if hovered == row.id {
            context.stroke(shape, with: .color(Theme.ink.opacity(0.4)), lineWidth: 1.5)
        }

        label(row, frame, &context)
    }

    private func hatch(_ frame: CGRect, _ clip: Path, _ hue: Color, _ context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: clip)
            // Spacing tracks block size: a fixed pitch turns a large block into
            // wallpaper, which stops reading as a warning.
            let step = min(26, max(7, frame.height / 22))
            var lines = Path()
            var x = frame.minX - frame.height
            while x < frame.maxX {
                lines.move(to: CGPoint(x: x, y: frame.maxY))
                lines.addLine(to: CGPoint(x: x + frame.height, y: frame.minY))
                x += step
            }
            layer.stroke(lines, with: .color(hue.opacity(0.4)), lineWidth: 1)
        }
    }

    private func label(_ row: ScanModel.Row, _ frame: CGRect, _ context: inout GraphicsContext) {
        guard frame.width > 86, frame.height > 40 else { return }
        let solid = row.tier <= Tier.automaticCeiling
        let primary = solid ? Color.white.opacity(0.96) : Theme.ink.opacity(0.8)

        context.draw(
            Text(row.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(primary),
            at: CGPoint(x: frame.minX + 11, y: frame.minY + 10), anchor: .topLeading)

        context.draw(
            Text(humanBytes(row.reclaimableBytes))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(primary),
            at: CGPoint(x: frame.minX + 10, y: frame.minY + 26), anchor: .topLeading)
    }
}
