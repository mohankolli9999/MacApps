import SwiftUI
import ReclaimCore

/// Everything in a directory too small to draw individually, drawn as one block.
///
/// Omitting it would make the blocks stop adding up to the folder they are in,
/// which is the one promise a treemap has to keep.
let remainderID = "storage.remainder"

/// The storage map's channels differ from the cache map's on purpose. There is
/// no ecosystem to colour by out here, and the only question the user is asking
/// is what it costs to remove a thing — so risk takes hue, and the surface says
/// whether there is anything inside worth opening.
enum RiskStyle {
    static func hue(_ risk: StorageRisk) -> Color {
        switch risk {
        case .safe: Color(hex: 0x4FB08A)
        case .yours: Color(hex: 0x5B8DEF)
        case .risky: Theme.warn
        case .blocked: Theme.muted
        }
    }

    static func label(_ risk: StorageRisk) -> String {
        switch risk {
        case .safe: "Rebuilt automatically"
        case .yours: "Yours — nothing rebuilds it"
        case .risky: "An app is using this"
        case .blocked: "Not this app's to remove"
        }
    }
}

struct StorageMapView: View {
    let nodes: [StorageNode]
    let remainder: Int64
    let selection: Set<String>
    /// Blocks whose sizes are still climbing. They are drawn, because watching
    /// them grow is the point of scanning branch by branch, but they cannot be
    /// opened or ticked: neither an empty folder nor a half-counted number is
    /// something to make a decision on.
    let measuring: Set<String>
    let risk: (StorageNode) -> StorageRisk
    let onOpen: (StorageNode) -> Void
    let onToggle: (StorageNode) -> Void
    @Binding var hovered: String?
    let paused: Bool
    let emptyMessage: String

    @State private var animator = TreemapAnimator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ordered by what each block gives back, sized by what it occupies.
    ///
    /// Only the order can follow reclaimable bytes. Area cannot: a folder
    /// duplicated in Finder shares every block with its twin, so both twins
    /// reclaim nothing and would draw as slivers — invisible, and too small to
    /// click into, which is how the map hides the very thing worth finding. The
    /// gap shows up as an unfilled block instead.
    private var targets: [TreemapNode] {
        var out = nodes.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
            .map { TreemapNode(id: $0.id, value: Double($0.physicalBytes)) }
        if remainder > 0 { out.append(TreemapNode(id: remainderID, value: Double(remainder))) }
        return out
    }

    /// The fraction of a block that is bytes the user would actually get back.
    private func reclaimShare(_ node: StorageNode) -> Double {
        guard node.physicalBytes > 0 else { return 1 }
        return min(1, Double(node.reclaimableBytes) / Double(node.physicalBytes))
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: paused)) { timeline in
                Canvas(rendersAsynchronously: false) { context, size in
                    let box = TreemapBox(x: 0, y: 0, width: size.width, height: size.height)
                    let laid = animator.advance(to: timeline.date, targets: targets,
                                                box: box, snap: reduceMotion)
                    let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                    for rect in laid {
                        if rect.id == remainderID {
                            drawRemainder(rect, &context)
                        } else if let node = byID[rect.id] {
                            draw(node, rect, &context)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in act(at: tap.location) })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = animator.hit(point)
                case .ended: hovered = nil
                }
            }
        }
        .background(Theme.stage)
        .overlay(alignment: .center) {
            if nodes.isEmpty && remainder == 0 {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
    }

    // MARK: - Interaction

    /// One click, two meanings, disambiguated by where it lands: the tick box
    /// marks a folder for removal, anywhere else opens it. A folder you can open
    /// and a folder you might delete are different intentions, and a modifier
    /// key would hide the second one from anybody who never finds it.
    private func act(at point: CGPoint) {
        guard let id = animator.hit(point), id != remainderID, !measuring.contains(id),
              let node = nodes.first(where: { $0.id == id }),
              let rect = animator.rects.first(where: { $0.id == id }) else { return }

        let box = frame(rect)
        if !node.isExplorable || tickBox(box).map({ $0.contains(point) }) == true {
            onToggle(node)
        } else {
            onOpen(node)
        }
    }

    private func frame(_ rect: TreemapRect) -> CGRect {
        let gutter = 1.5
        return CGRect(x: rect.x + gutter, y: rect.y + gutter,
                      width: max(0, rect.width - gutter * 2),
                      height: max(0, rect.height - gutter * 2))
    }

    /// Nil when the block is too small to carry one, in which case the whole
    /// block toggles rather than opening — a sliver you cannot aim at is worse
    /// than no affordance.
    private func tickBox(_ frame: CGRect) -> CGRect? {
        guard frame.width > 62, frame.height > 46 else { return nil }
        return CGRect(x: frame.minX + 7, y: frame.minY + 7, width: 18, height: 18)
    }

    // MARK: - Drawing

    private func draw(_ node: StorageNode, _ rect: TreemapRect, _ context: inout GraphicsContext) {
        let box = frame(rect)
        guard box.width > 1, box.height > 1 else { return }

        let level = risk(node)
        let hue = RiskStyle.hue(level)
        let shape = Path(roundedRect: box, cornerRadius: min(4, box.height / 3))
        let chosen = selection.contains(node.id)
        let counting = measuring.contains(node.id)

        let solid = counting ? 0.14 : node.isDirectory ? 0.30 : 0.62
        let share = reclaimShare(node)
        if share > 0.98 {
            context.fill(shape, with: .color(hue.opacity(solid)))
        } else {
            // Filled from the bottom to the share that is really free, so a block
            // standing mostly empty reads as "big, and hands almost none of it
            // back" without needing to be read.
            context.fill(shape, with: .color(hue.opacity(solid * 0.22)))
            context.drawLayer { layer in
                layer.clip(to: shape)
                let filled = box.height * share
                layer.fill(Path(CGRect(x: box.minX, y: box.maxY - filled,
                                       width: box.width, height: filled)),
                           with: .color(hue.opacity(solid)))
            }
        }

        // A folder reads as a container: a lighter lid at the top edge, so the
        // thing you can open looks openable without needing a label to say so.
        if node.isDirectory, box.height > 14 {
            context.drawLayer { layer in
                layer.clip(to: shape)
                layer.fill(Path(CGRect(x: box.minX, y: box.minY, width: box.width, height: 3)),
                           with: .color(hue.opacity(0.85)))
            }
        }
        if level == .blocked {
            hatch(box, shape, hue, &context)
        }

        if chosen {
            context.fill(shape, with: .color(hue.opacity(0.35)))
            context.stroke(shape, with: .color(Theme.ink), lineWidth: 2)
        } else if hovered == node.id {
            context.stroke(shape, with: .color(Theme.ink.opacity(0.45)), lineWidth: 1.5)
        } else {
            context.stroke(shape, with: .color(hue.opacity(0.55)), lineWidth: 0.75)
        }

        if let tick = tickBox(box), level.isTrashable, !counting {
            drawTick(tick, checked: chosen, lit: chosen || hovered == node.id, &context)
        }
        label(node, box, chosen, counting, &context)
    }

    private func drawTick(_ box: CGRect, checked: Bool, lit: Bool, _ context: inout GraphicsContext) {
        let shape = Path(roundedRect: box, cornerRadius: 4)
        context.fill(shape, with: .color(Theme.stageEdge.opacity(checked ? 0.95 : 0.55)))
        context.stroke(shape, with: .color(Theme.ink.opacity(lit ? 0.9 : 0.35)), lineWidth: 1)
        guard checked else { return }
        var mark = Path()
        mark.move(to: CGPoint(x: box.minX + 4.5, y: box.midY))
        mark.addLine(to: CGPoint(x: box.midX - 0.5, y: box.maxY - 5))
        mark.addLine(to: CGPoint(x: box.maxX - 4, y: box.minY + 5))
        context.stroke(mark, with: .color(Theme.ink),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawRemainder(_ rect: TreemapRect, _ context: inout GraphicsContext) {
        let box = frame(rect)
        guard box.width > 1, box.height > 1 else { return }
        let shape = Path(roundedRect: box, cornerRadius: min(4, box.height / 3))
        context.fill(shape, with: .color(Theme.hairline.opacity(0.55)))
        context.stroke(shape, with: .color(Theme.hairline), lineWidth: 1)
        guard box.width > 92, box.height > 34 else { return }
        context.draw(
            Text("Everything smaller")
                .font(.system(size: 11)).foregroundStyle(Theme.muted),
            at: CGPoint(x: box.minX + 10, y: box.minY + 9), anchor: .topLeading)
    }

    private func hatch(_ box: CGRect, _ clip: Path, _ hue: Color, _ context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: clip)
            let step = min(26, max(7, box.height / 22))
            var lines = Path()
            var x = box.minX - box.height
            while x < box.maxX {
                lines.move(to: CGPoint(x: x, y: box.maxY))
                lines.addLine(to: CGPoint(x: x + box.height, y: box.minY))
                x += step
            }
            layer.stroke(lines, with: .color(hue.opacity(0.35)), lineWidth: 1)
        }
    }

    private func label(_ node: StorageNode, _ box: CGRect, _ chosen: Bool,
                       _ counting: Bool, _ context: inout GraphicsContext) {
        guard box.width > 86, box.height > 40 else { return }
        let inset: CGFloat = tickBox(box) == nil || counting ? 0 : 24
        let ink = Theme.ink.opacity(counting ? 0.55 : chosen ? 1 : 0.9)

        context.draw(
            Text(node.name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink),
            at: CGPoint(x: box.minX + 9 + inset, y: box.minY + 9), anchor: .topLeading)

        guard box.height > 58 else { return }
        // A number that is still climbing invites a decision it cannot support,
        // so a branch mid-count says what it is doing instead of how big it is.
        context.draw(
            counting
                ? Text("counting…").font(.system(size: 13)).foregroundStyle(ink)
                : Text(humanBytes(node.reclaimableBytes))
                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ink),
            at: CGPoint(x: box.minX + 9, y: box.minY + 28), anchor: .topLeading)

        // The only place the occupied size is spoken aloud, and only where it
        // disagrees with the freed size — otherwise it is a second answer to a
        // question the user did not ask twice.
        guard !counting, box.height > 80, box.width > 150, reclaimShare(node) <= 0.98 else { return }
        context.draw(
            Text("of \(humanBytes(node.physicalBytes)) — the rest is shared")
                .font(.system(size: 10)).foregroundStyle(Theme.muted),
            at: CGPoint(x: box.minX + 9, y: box.minY + 53), anchor: .topLeading)
    }
}
