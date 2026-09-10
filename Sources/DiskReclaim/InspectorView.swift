import SwiftUI
import ReclaimCore

struct InspectorView: View {
    let row: ScanModel.Row?
    let model: ScanModel

    var body: some View {
        ScrollView {
            if let row {
                detail(row)
            } else {
                overview
            }
        }
        .frame(width: 268)
        .background(Theme.stageEdge)
    }

    /// An empty pane is dead space. With nothing selected the inspector answers
    /// the question the treemap raises: what did the scan actually find?
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a block to see how it comes back.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 12) {
                figure(humanBytes(model.measuredBytes), "measured across \(model.rows.count) caches")
                figure(humanBytes(model.reclaimableBytes),
                       model.reclaimable.count == 1
                           ? "backed by 1 proven recipe"
                           : "backed by \(model.reclaimable.count) proven recipes")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detail(_ row: ScanModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.hue(for: row.id)).frame(width: 9, height: 9)
                    Text(row.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                Text(row.path)
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                figure(humanBytes(row.reclaimableBytes), "reclaimable")
                if row.fileCount > 0 {
                    figure(row.fileCount.formatted(), row.fileCount == 1 ? "file" : "files")
                }
            }

            // Ecosystem hue would make "free to refetch" read as npm's alarm red.
            // The badge speaks about recoverability, so it borrows the legend's
            // vocabulary instead: same swatch, same neutral ink.
            HStack(spacing: 7) {
                LegendSwatch(tier: row.tier)
                Text(Theme.label(for: row.tier))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.9))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Theme.ink.opacity(0.08), in: Capsule())

            Divider().overlay(Theme.hairline)

            restore(row)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text(caption).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private func restore(_ row: ScanModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it comes back")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)

            if let recipe = row.recipe {
                if recipe.kind == .automatic {
                    Text(recipe.command)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(recipe.command)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))

                    Button("Copy commands") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recipe.command, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }

                if let bytes = recipe.cost.bytesToRefetch, bytes > 0 {
                    Text("Downloads \(humanBytes(bytes)) again.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            } else {
                Text(row.note ?? "No proven way to restore this, so it stays put.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
