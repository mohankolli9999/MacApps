import AppKit
import SwiftUI
import ReclaimCore

@MainActor
@Observable
final class LicenseModel {
    private(set) var entitlement: Entitlement = .trial(used: 0, allowance: Entitlements.trialAllowance)
    /// Why the last key was turned away, in the user's words rather than the
    /// error's. Cleared as soon as they change what is in the field.
    private(set) var refusal: String?

    private let store: LicenseStore
    private let manifest: ManifestStore

    init() {
        store = .standard
        manifest = .standard
        refresh()
    }

    /// Cheap enough to call after every removal: the manifest is a few hundred
    /// lines on a machine that has been reclaiming for a year.
    func refresh() {
        entitlement = Entitlements.current(license: store.load(),
                                           reclaimed: Entitlements.reclaimed(from: manifest))
    }

    func enter(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try store.save(text)
            refusal = nil
            refresh()
        } catch LicenseFault.unknownFormat(let tag) {
            refusal = "That key is in the \(tag) format, which this version does not know. A newer Disk Reclaim will read it."
        } catch LicenseFault.malformed {
            refusal = "That does not look like a licence key. It starts with DRCL1 and has no spaces in it."
        } catch {
            refusal = "That key is not one we issued, or it was edited after it was issued."
        }
    }

    func clearRefusal() { refusal = nil }

    func remove() {
        store.clear()
        refusal = nil
        refresh()
    }

    var license: License? {
        if case .licensed(let license) = entitlement { return license }
        return nil
    }

    var canReclaim: Bool { entitlement.canReclaim }

    /// The one line the footer shows when the buttons are off.
    var blockedReason: String? {
        guard case .spent(let allowance) = entitlement else { return nil }
        return "The \(humanBytes(allowance)) trial is used up. Everything still measures; removing needs a licence."
    }
}

struct LicenseSheet: View {
    @Bindable var model: LicenseModel
    let onClose: () -> Void

    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(heading)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(subheading)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider().overlay(Theme.hairline)

            if let license = model.license {
                registered(license)
            } else {
                entry
            }
        }
        .frame(width: 460)
        .background(Theme.stage)
    }

    private var heading: String {
        switch model.entitlement {
        case .licensed: "Licensed"
        case .trial: "Trial"
        case .spent: "Trial finished"
        }
    }

    private var subheading: String {
        switch model.entitlement {
        case .licensed(let license):
            "Registered to \(license.name)."
        case .trial(let used, let allowance):
            "\(humanBytes(allowance - used)) of the \(humanBytes(allowance)) trial left. "
            + "Measuring is never limited — the trial only counts what you actually remove."
        case .spent(let allowance):
            "You have reclaimed the \(humanBytes(allowance)) this trial covers. Measuring keeps working; "
            + "removing needs a licence."
        }
    }

    private func registered(_ license: License) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                field("Name", license.name)
                field("Email", license.email)
                field("Order", license.order)
                field("Issued", license.issued.formatted(date: .abbreviated, time: .omitted))
            }
            // Nothing was ever asked of a server, so nothing has to be told about
            // this either. Saying so is the reassurance; a progress spinner
            // pretending to contact something would be the opposite.
            Text("Checked on this Mac against a key built into the app. Disk Reclaim has never contacted anything.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Remove Licence") { model.remove() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .frame(width: 48, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Theme.ink)
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste your licence key")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)

            TextEditor(text: $typed)
                .font(.system(size: 11).monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 72)
                .background(Theme.stageEdge)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
                .onChange(of: typed) { model.clearRefusal() }

            if let refusal = model.refusal {
                Text(refusal)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Paste") {
                    typed = NSPasteboard.general.string(forType: .string) ?? typed
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)

                Spacer()
                Button("Not Now") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Unlock") {
                    model.enter(typed)
                    if model.license != nil { onClose() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

/// The header's licence affordance. Silent while the trial has room, because a
/// permanent nag is what makes people uninstall a tool they were about to buy.
struct LicenseBadge: View {
    @Bindable var model: LicenseModel
    let onOpen: () -> Void

    var body: some View {
        switch model.entitlement {
        case .licensed:
            EmptyView()
        case .trial(let used, let allowance):
            button("\(humanBytes(allowance - used)) trial left", Theme.muted)
        case .spent:
            button("Trial finished", Theme.warn)
        }
    }

    private func button(_ text: String, _ tint: Color) -> some View {
        Button(action: onOpen) {
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help("Enter a licence key")
    }
}
