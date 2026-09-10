import SwiftUI
import ReclaimCore

@MainActor
@Observable
final class SystemStorageModel {
    private(set) var report: VolumeLedger.Report?
    private(set) var isReading = false
    private(set) var failed = false

    func read() {
        guard !isReading else { return }
        isReading = true
        Task {
            let answer = await Task.detached(priority: .userInitiated) {
                try? VolumeLedger.read()
            }.value
            report = answer ?? report
            failed = answer == nil
            isReading = false
        }
    }
}

/// Where the bytes go that no folder explains.
///
/// System Settings calls the difference "System Data" and says nothing more, so
/// people go looking for a 20 GB folder that does not exist. Every number here
/// belongs to something the folder map structurally cannot reach: volumes macOS
/// hides, blocks a snapshot is still holding for a file you deleted, and the
/// container's own bookkeeping. None of it is removable from this app, and
/// saying that is the point — an unexplained gap is what makes people delete
/// things they need.
struct SystemView: View {
    @Bindable var model: SystemStorageModel

    /// The bar is the one place this screen raises its voice. Ranked by how much
    /// agency the user has over the segment: bright where a folder walk can go,
    /// receding through the parts it cannot.
    private enum Band {
        static let browsable = Theme.ink.opacity(0.70)
        static let hidden = Color(hex: 0x5B8DEF).opacity(0.62)
        static let overhead = Color(hex: 0x4FA8A8).opacity(0.55)
        static let free = Theme.hairline
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let report = model.report {
                    ForEach(report.containers) { container in
                        containerSection(container)
                    }
                    snapshotSection(report)
                    purgeableSection(report)
                    closing
                } else if model.isReading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                } else if model.failed {
                    Text("diskutil did not answer, so this Mac's volume layout is unknown. Everything else in the app still works.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 60)
                }
            }
            .padding(22)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.stage)
        .task { model.read() }
    }

    // MARK: - One container

    private func containerSection(_ c: VolumeLedger.Container) -> some View {
        let browsable = c.volumes.filter { !$0.isHidden }
        let hidden = c.volumes.filter(\.isHidden)
        let browsableBytes = browsable.reduce(Int64(0)) { $0 + $1.usedBytes }
        let hiddenBytes = hidden.reduce(Int64(0)) { $0 + $1.usedBytes }

        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(browsable.first?.name ?? c.device)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(c.device)
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(Theme.muted.opacity(0.7))
                Spacer()
                Text(humanBytes(c.capacityBytes))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }

            capacityBar(c, browsableBytes: browsableBytes, hiddenBytes: hiddenBytes)

            VStack(spacing: 0) {
                band(Band.browsable, "Volumes you can browse", browsableBytes,
                     detail: browsable.map(\.name).joined(separator: " + ")
                         + " — what the Storage tab measures.")

                if hiddenBytes > 0 {
                    band(Band.hidden, "Volumes macOS hides", hiddenBytes,
                         detail: "On the same disk, behind no folder. Not removable.")
                    ForEach(hidden) { volume in
                        hiddenRow(volume)
                    }
                }

                band(Band.overhead, "Container bookkeeping", c.unaccountedBytes,
                     detail: "Checkpoints, allocation maps and superblocks APFS keeps outside every volume.")

                band(Band.free, "Free", c.freeBytes, detail: nil)
            }
        }
    }

    private func capacityBar(_ c: VolumeLedger.Container,
                             browsableBytes: Int64,
                             hiddenBytes: Int64) -> some View {
        GeometryReader { geo in
            // A 160 MB residual on a 494 GB disk is a third of a pixel. Drawing
            // it at a legible minimum overstates it, so it stays sub-pixel and
            // the row below carries the number instead.
            let scale = geo.size.width / Double(max(1, c.capacityBytes))
            HStack(spacing: 0) {
                Rectangle().fill(Band.browsable).frame(width: Double(browsableBytes) * scale)
                Rectangle().fill(Band.hidden).frame(width: Double(hiddenBytes) * scale)
                Rectangle().fill(Band.overhead).frame(width: Double(c.unaccountedBytes) * scale)
                Rectangle().fill(Band.free)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func band(_ colour: Color, _ title: String, _ bytes: Int64,
                      detail: String?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(colour)
                .frame(width: 9, height: 9)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text(humanBytes(bytes))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.ink.opacity(0.85))
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline.opacity(0.45)).frame(height: 1)
        }
    }

    private func hiddenRow(_ volume: VolumeLedger.Volume) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name).font(.system(size: 11.5)).foregroundStyle(Theme.ink.opacity(0.9))
                Text(Self.purpose(of: volume))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(humanBytes(volume.usedBytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
        .padding(.leading, 18)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline.opacity(0.25)).frame(height: 1).padding(.leading, 18)
        }
    }

    private static func purpose(of volume: VolumeLedger.Volume) -> String {
        switch volume.roles.first {
        case "Preboot": "Boot files for every macOS version installed here, including the sealed system's cryptexes."
        case "Recovery": "The recovery system you boot into with the power button held."
        case "VM": "Swap and the sleep image. macOS grows and shrinks this on its own."
        case "Update": "A macOS installer staged for a restart. It clears once the update finishes."
        case "xART": "Secure Enclave key storage."
        case "Hardware": "Firmware and hardware configuration."
        default: "Reserved by macOS."
        }
    }

    // MARK: - Snapshots

    private func snapshotSection(_ report: VolumeLedger.Report) -> some View {
        let names = Dictionary(uniqueKeysWithValues:
            report.containers.flatMap(\.volumes).map { ($0.device, $0.name) })
        let devices = report.snapshots.keys.sorted()

        return VStack(alignment: .leading, spacing: 11) {
            Text("Snapshots")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)

            if devices.isEmpty {
                Text("None. Nothing on this Mac is holding blocks for files you already deleted.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
            } else {
                // The honest limit of this section. `diskutil apfs listSnapshots`
                // names each snapshot and says nothing about its size, and there
                // is no unprivileged call that does — so the count is real and
                // any number beside it would be invented.
                Text("A snapshot keeps the old version of every block a file had when it was taken, which is how deleting something can free nothing. macOS reports which snapshots exist but not what each one holds, so there is no size to show here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(devices, id: \.self) { device in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 7) {
                            Text(names[device] ?? device)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text(device)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(Theme.muted.opacity(0.7))
                        }
                        .padding(.top, 8)

                        ForEach(report.snapshots[device] ?? []) { snapshot in
                            HStack(spacing: 8) {
                                Text(snapshot.name)
                                    .font(.system(size: 10.5).monospaced())
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(snapshot.isPurgeable ? "macOS may drop it" : "kept")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(snapshot.isPurgeable
                                                     ? Theme.muted
                                                     : Theme.ink.opacity(0.7))
                            }
                            .padding(.vertical, 5)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Theme.hairline.opacity(0.3)).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Purgeable

    @ViewBuilder
    private func purgeableSection(_ report: VolumeLedger.Report) -> some View {
        if let purgeable = report.purgeableBytes {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Purgeable")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(humanBytes(purgeable))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                Text("Counted as used, but macOS gives it back by itself the moment the disk gets tight: caches it can refetch, snapshots it can drop, files already safe in iCloud. Deleting these yourself gains nothing you were not going to get anyway.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var closing: some View {
        Text("Nothing on this screen can be removed from here, and most of it should not be removed at all. It is listed so the disk adds up.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}
