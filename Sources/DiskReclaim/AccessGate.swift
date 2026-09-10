import AppKit
import SwiftUI
import ReclaimCore

/// First run, and any time the user asks to revisit the permission.
///
/// macOS has no API to raise the Full Disk Access sheet, so this screen does the
/// only two things an app is allowed to do: say plainly what the permission buys,
/// and open the pane where it is granted. It then watches for the answer, because
/// asking someone to come back and click Continue after they have already said
/// yes somewhere else is a needless second ask.
struct AccessGate: View {
    let access: FullDiskAccess.Access
    let onContinue: () -> Void

    private var granted: Bool { access == .granted }

    /// Claiming the permission is missing when the probe only failed to find
    /// anything to test is how an app sends someone into Settings to grant what
    /// they granted last week.
    private var detail: String {
        switch access {
        case .granted: "The whole disk is visible, so the totals will be complete."
        case .denied: "Without it, parts of your Library and other users' folders stay hidden and the totals read low."
        case .unknown: "This Mac gave no answer either way. If it turns out to be missing, parts of your Library stay hidden and the totals read low."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 7) {
                Text("Disk Reclaim")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Find what is filling this Mac, and remove only what you choose.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 15) {
                promise("wifi.slash", "Nothing leaves this Mac",
                        "There is no network code in the app. It cannot phone home because it has nothing to phone home with.")
                promise("hand.raised.fill", "Nothing goes without you choosing it",
                        "The scan only reads sizes. Removal happens when you tick something and confirm it.")
                promise("arrow.uturn.backward", "Removal means the Trash",
                        "Files you pick are moved, not erased. Put Back in Finder undoes any of it.")
            }
            .frame(width: 430)
            .padding(.top, 30)

            accessRow
                .frame(width: 430)
                .padding(.top, 26)

            Button(granted ? "Continue" : "Continue without it", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.stage)
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessRow: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(granted ? Color(hex: 0x4FB08A) : Theme.warn)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(granted ? "Full Disk Access granted" : "Full Disk Access")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !granted {
                Button("Open Settings…") {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((granted ? Color(hex: 0x4FB08A) : Theme.warn).opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder((granted ? Color(hex: 0x4FB08A) : Theme.warn).opacity(0.28), lineWidth: 1)
        )
    }
}
