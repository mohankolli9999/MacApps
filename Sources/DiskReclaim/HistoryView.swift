import SwiftUI
import ReclaimCore

/// The manifest, made visible. Reclaiming is only safe because the way back was
/// written down first, and a promise the user cannot inspect is not a promise.
struct HistoryView: View {
    let model: ScanModel

    var body: some View {
        ScrollView {
            if model.history.isEmpty {
                empty
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    summary
                    ForEach(model.history) { plan in
                        row(plan)
                        Divider().overlay(Theme.hairline.opacity(0.6))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.stage)
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Text("Nothing reclaimed yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("Reclaim a cache and the exact command that brings it back is written here first.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var runnable: Int {
        model.history.count { $0.entry.recipe.isConcrete }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(humanBytes(model.reclaimedBytes))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text(model.history.count == 1
                     ? "freed in 1 reclaim"
                     : "freed across \(model.history.count) reclaims")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

            // Counting a template as "recorded" would be the exact false comfort
            // this log exists to refuse. Say plainly how many can actually run.
            Text(runnable == model.history.count
                 ? "Every one recorded a way back."
                 : "\(runnable) of \(model.history.count) recorded a way back.")
                .font(.system(size: 11))
                .foregroundStyle(runnable == model.history.count ? Theme.muted : Theme.warn)

            if model.unreadableHistoryLines > 0 {
                Text(model.unreadableHistoryLines == 1
                     ? "1 entry in the log is damaged and cannot be read."
                     : "\(model.unreadableHistoryLines) entries in the log are damaged and cannot be read.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func row(_ plan: RestorePlan) -> some View {
        let entry = plan.entry
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.hue(for: entry.artefactID))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(model.displayName(forArtefact: entry.artefactID))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(humanBytes(entry.bytesFreed))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 12)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }

            Text(entry.path)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)

            Text(plan.command)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(entry.recipe.isConcrete ? Theme.ink : Theme.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 5))

            if !entry.recipe.isConcrete {
                Text("A template, not a command. It never recorded which one was removed, so this will not bring it back.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                if entry.recipe.isRunnableCommand {
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.command, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }

                if plan.isRestored {
                    Label("Restored", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                } else {
                    Button("Mark restored") { model.markRestored(plan) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("Records that you have run this command. It is never run for you.")
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .opacity(plan.isRestored ? 0.55 : 1)
    }
}
