import SwiftUI
import ReclaimCore

struct StorageView: View {
    @Bindable var model: StorageModel
    let access: FullDiskAccess.Access
    @Bindable var licence: LicenseModel
    let onRequestAccess: () -> Void
    let onOpenLicence: () -> Void

    @State private var hovered: String?
    @State private var confirming = false
    @State private var paused = true
    /// Which footer counter has its list open, if any.
    @State private var opened: String?

    var body: some View {
        VStack(spacing: 0) {
            locationBar
            Divider().overlay(Theme.hairline)

            if model.tree == nil {
                model.isScanning ? AnyView(opening) : AnyView(idle)
            } else {
                if model.isScanning { scanStrip }
                if access != .granted { accessBanner }
                HStack(spacing: 0) {
                    StorageMapView(nodes: model.listing,
                                   remainder: model.current?.unlistedBytes ?? 0,
                                   selection: model.selection,
                                   measuring: model.measuring,
                                   risk: { model.risk(of: $0) },
                                   onOpen: { node in withAnimation(.easeOut(duration: 0.18)) { model.open(node) } },
                                   onToggle: model.toggle,
                                   hovered: $hovered,
                                   paused: paused,
                                   emptyMessage: emptyMessage)
                    Divider().overlay(Theme.hairline)
                    listing.frame(width: 300)
                }
                Divider().overlay(Theme.hairline)
                if !model.collector.isEmpty { tray }
                footer
            }
        }
        .background(Theme.stage)
        .task(id: model.trail) {
            // Run the tween, then stop the display link. Redrawing a settled map
            // at 120Hz is a battery leak with nothing to show for it.
            paused = false
            try? await Task.sleep(for: .milliseconds(700))
            paused = true
        }
        // Branches land one at a time, so the map keeps rearranging long after
        // the first frame. Keep the tween running for as long as that lasts.
        .task(id: model.isScanning) {
            if model.isScanning {
                paused = false
            } else {
                try? await Task.sleep(for: .milliseconds(900))
                paused = true
            }
        }
        .sheet(isPresented: $confirming) { confirmation }
    }

    private var emptyMessage: String {
        access == .granted
            ? "Nothing in here is large enough to draw."
            : "Nothing readable in here.\nSome of it may need Full Disk Access."
    }

    // MARK: - Location

    private var locationBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { model.root },
                                          set: { model.choose($0) })) {
                ForEach(model.roots) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isScanning)

            crumbs

            Spacer(minLength: 8)

            if let here = model.current {
                HStack(spacing: 4) {
                    Text(humanBytes(here.reclaimableBytes))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text("to reclaim")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                .help("What emptying this folder would give the volume back. Blocks that occupy more than they would return are drawn part-empty.")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.stageEdge)
    }

    private var crumbs: some View {
        HStack(spacing: 3) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { depth, node in
                if depth > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                }
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.rise(to: depth) }
                } label: {
                    Text(depth == 0 ? model.root.name : node.name)
                        .font(.system(size: 11.5,
                                      weight: depth == model.trail.count ? .semibold : .regular))
                        .foregroundStyle(depth == model.trail.count ? Theme.ink : Theme.muted)
                }
                .buttonStyle(.plain)
                .disabled(depth == model.trail.count)
            }
        }
    }

    // MARK: - States

    /// The gap between pressing Start and the first branch appearing — one
    /// listing of the root, so well under a second on any disk.
    private var opening: some View {
        VStack(spacing: 10) {
            Spacer()
            capacity
            ProgressView().controlSize(.small)
            Text("Opening \(model.root.name)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Button("Stop") { model.cancel() }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// The one true thing available before any walking happens.
    ///
    /// A full scan is a minute or more and every frame of it used to be blank,
    /// which is indistinguishable from a hung app and is most of what "the app
    /// is slow" actually describes. This costs a syscall and answers the first
    /// question anyone opens the app with.
    @ViewBuilder private var capacity: some View {
        if let space = model.space {
            VStack(spacing: 7) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline.opacity(0.6))
                        Capsule().fill(Theme.ink.opacity(0.55))
                            .frame(width: geo.size.width
                                   * min(1, Double(space.used) / Double(max(1, space.capacity))))
                    }
                }
                .frame(width: 320, height: 6)

                Text("\(humanBytes(space.used)) used · \(humanBytes(space.free)) free of \(humanBytes(space.capacity))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 6)
        }
    }

    /// The map is live from the first branch, so the running total belongs in a
    /// strip beside it rather than on a screen of its own. What it has to say is
    /// that the numbers below are still going up.
    private var scanStrip: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12)

            Text(humanBytes(model.progress?.bytes ?? 0))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: model.progress?.bytes)

            Text(model.measuring.count == 1
                 ? "so far · 1 folder left to count"
                 : "so far · \(model.measuring.count) folders left to count")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)

            Text(abbreviate(model.progress?.location ?? model.root.url.path))
                .font(.system(size: 10.5).monospaced())
                .foregroundStyle(Theme.muted.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 320, alignment: .leading)

            Spacer(minLength: 8)

            Button("Stop") { model.cancel() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.stageEdge)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var idle: some View {
        VStack(spacing: 12) {
            Spacer()
            capacity
            Text("Measure \(model.root.name)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Everything happens on this Mac. Nothing is uploaded, and nothing is\nremoved until you pick it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Start") { model.scan() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var accessBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.warn)
            Text(accessNote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.85))
            Spacer()
            Button("Grant Access…") { onRequestAccess() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.warn)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.warn.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// What the scan hit beats what the permission probe guessed. A count of
    /// refused folders is evidence; `.unknown` is the probe admitting it found
    /// nothing to test against, and stating that is better than asserting a
    /// denial the user may already have lifted.
    private var accessNote: String {
        if model.unreadableLocations > 0 {
            return "\(model.unreadableLocations) locations could not be read. Totals here are lower than the truth."
        }
        return access == .denied
            ? "Without Full Disk Access some folders stay hidden from this map."
            : "Full Disk Access could not be checked on this Mac. If totals look low, that is the likely reason."
    }

    // MARK: - Listing

    private var listing: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.listing) { node in
                    row(node)
                    Divider().overlay(Theme.hairline.opacity(0.4))
                }
                if let extra = model.current?.unlistedBytes, extra > 0 {
                    remainderRow(extra)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.stageEdge.opacity(0.5))
    }

    private func row(_ node: StorageNode) -> some View {
        let level = model.risk(of: node)
        let counting = model.measuring.contains(node.id)
        let share = Double(node.reclaimableBytes) / Double(max(1, model.current?.reclaimableBytes ?? 1))
        return HStack(spacing: 9) {
            Toggle("", isOn: Binding(get: { model.selection.contains(node.id) },
                                     set: { _ in model.toggle(node) }))
                .labelsHidden()
                .disabled(!level.isTrashable || counting)
                .help(counting ? "Still being counted"
                      : level.isTrashable ? "Select for the Trash" : RiskStyle.label(level))

            Button {
                withAnimation(.easeOut(duration: 0.18)) { model.open(node) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(RiskStyle.hue(level))
                        Text(node.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(counting ? "counting…" : humanBytes(node.reclaimableBytes))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            // Without this a 40 GB folder that shares every block
                            // with a copy elsewhere reads as an empty folder.
                            .help(node.reclaimableBytes < node.physicalBytes
                                  ? "Occupies \(humanBytes(node.physicalBytes)). The rest is shared with copies elsewhere, so removing this alone does not return it."
                                  : "Removing this returns \(humanBytes(node.reclaimableBytes)).")
                    }
                    // The bar repeats the number as length, which is the only form
                    // you can compare down a column without reading every row.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline.opacity(0.6))
                            Capsule().fill(RiskStyle.hue(level).opacity(0.85))
                                .frame(width: max(2, geo.size.width * share))
                        }
                    }
                    .frame(height: 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!node.isExplorable || counting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovered == node.id ? Theme.ink.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
        .contextMenu {
            Button("Reveal in Finder") { model.reveal(node) }
            if level.isTrashable {
                Button(model.selection.contains(node.id) ? "Deselect" : "Select") {
                    model.toggle(node)
                }
            }
        }
    }

    private func remainderRow(_ bytes: Int64) -> some View {
        HStack(spacing: 9) {
            Text("Everything smaller")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
            Spacer()
            Text(humanBytes(bytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Items under \(humanBytes(VolumeScanner.defaultListThreshold)) are counted here rather than drawn.")
    }

    // MARK: - Tray

    /// Everything picked so far, from wherever it was picked.
    ///
    /// Selection used to be scoped to the folder on screen and cleared on the
    /// way out of it, so clearing 40 GB spread over five folders meant five
    /// deletes, each quoting a number that ignored the other four. Holding the
    /// picks makes it one act — and lets the estimate see two clones of each
    /// other at once, which is the only way its total can be exact.
    private var tray: some View {
        HStack(spacing: 10) {
            Text("Picked")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.collector.items) { node in
                        HStack(spacing: 5) {
                            Circle().fill(RiskStyle.hue(model.risk(of: node)))
                                .frame(width: 6, height: 6)
                            Text(node.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text(humanBytes(node.reclaimableBytes))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                            Button { model.discard(id: node.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain)
                            .help("Take out of the tray")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.ink.opacity(0.07)))
                        .help(node.url.path)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)

            Button("Clear") { model.clearCollector() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.stageEdge)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            riskKey(.safe)
            riskKey(.yours)
            riskKey(.risky)

            if model.unreadableLocations > 0 {
                counter(id: "unreadable",
                        label: model.unreadableLocations == 1
                            ? "1 folder could not be read"
                            : "\(model.unreadableLocations) folders could not be read",
                        note: "The scan was refused these, so their bytes are missing from every total above. Full Disk Access is almost always the reason.",
                        paths: model.unreadablePaths,
                        total: model.unreadableLocations,
                        tint: Theme.warn)
            }

            if model.cloudOnlyLocations > 0 {
                counter(id: "cloud",
                        label: model.cloudOnlyLocations == 1
                            ? "1 folder stored online"
                            : "\(model.cloudOnlyLocations) folders stored online",
                        note: "iCloud, OneDrive and Dropbox keep folders whose contents live on a server. They take no space here, and opening one would download it, so the scan leaves them alone.",
                        paths: model.cloudOnlyPaths,
                        total: model.cloudOnlyLocations,
                        tint: Theme.muted)
            }

            if model.offVolumeLocations > 0 {
                counter(id: "offvolume",
                        label: model.offVolumeLocations == 1
                            ? "1 place on another disk"
                            : "\(model.offVolumeLocations) places on other disks",
                        note: "The scan stops where a folder continues onto a mounted disk image or a network share. Those bytes belong to that disk, so they are missing from the totals here.",
                        paths: model.offVolumePaths,
                        total: model.offVolumeLocations,
                        tint: Theme.muted)
            }

            // Deliberately worded as somewhere the scan *went*, not somewhere it
            // stopped: these are followed, and the bytes past them are already in
            // the totals above. Sharing the "places we did not look" phrasing
            // would turn a complete number into one that reads as incomplete.
            if model.firmlinkCrossings > 0 {
                Text(model.firmlinkCrossings == 1
                     ? "crossed onto 1 system volume"
                     : "crossed onto \(model.firmlinkCrossings) system volumes")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .help("macOS splits the startup disk into a sealed system volume and a data volume, then stitches them back together so they look like one. Folders such as Users and Applications live on the data half. The scan follows across and counts them — this is only saying that some of what you see above is on the other half.")
            }

            Spacer()

            if let blocked = licence.blockedReason {
                Text(blocked).font(.system(size: 11)).foregroundStyle(Theme.warn)
            } else if let note = model.lastAction {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }

            if !model.selection.isEmpty {
                Text(model.isEstimating
                     ? "\(model.selection.count) selected · frees at least \(humanBytes(model.selectedBytes))"
                     : "\(model.selection.count) selected · frees \(humanBytes(model.selectedBytes))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }

            if licence.canReclaim {
                Button("Move to Trash…") { confirming = true }
                    .disabled(model.selection.isEmpty)
            } else {
                Button("Unlock to Remove…") { onOpenLicence() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// A tally of places the totals could not reach, and the places themselves.
    ///
    /// The count alone says some number of gigabytes is unaccounted for and
    /// gives nobody a way to find out which — which reads as a bug in a tool
    /// whose entire claim is that its number is honest.
    private func counter(id: String,
                         label: String,
                         note: String,
                         paths: [String],
                         total: Int,
                         tint: Color) -> some View {
        Button { opened = opened == id ? nil : id } label: {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11)).foregroundStyle(tint)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .help(note)
        .popover(isPresented: Binding(get: { opened == id },
                                      set: { if !$0 { opened = nil } }),
                 arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Divider().overlay(Theme.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(paths, id: \.self) { path in
                            Button { model.reveal(path: path) } label: {
                                Text(abbreviate(path))
                                    .font(.system(size: 10.5).monospaced())
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1).truncationMode(.head)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 220)
                // The list is capped so a scan of `/` without Full Disk Access
                // does not try to draw thousands of rows. Saying so is better
                // than a list that silently stops.
                if total > paths.count {
                    Divider().overlay(Theme.hairline)
                    Text("and \(total - paths.count) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }
            .frame(width: 380)
        }
    }

    private func riskKey(_ level: StorageRisk) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(RiskStyle.hue(level).opacity(0.62))
                .frame(width: 11, height: 11)
            Text(RiskStyle.label(level)).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: - Confirmation

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.selection.count == 1
                     ? "Move this to the Trash?"
                     : "Move these \(model.selection.count) items to the Trash?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(warning)
                    .font(.system(size: 12))
                    .foregroundStyle(model.selectionRisk == .risky ? Theme.warn : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.selectedNodes) { node in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(RiskStyle.hue(model.risk(of: node)))
                                .frame(width: 7, height: 7).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(node.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                    Text(humanBytes(node.reclaimableBytes))
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(Theme.muted)
                                }
                                Text(node.url.path)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        Divider().overlay(Theme.hairline.opacity(0.5))
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isEstimating
                         ? "Frees at least \(humanBytes(model.selectedBytes)) once the Trash is emptied"
                         : "Frees \(humanBytes(model.selectedBytes)) once the Trash is emptied")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    if let note = sharedNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Cancel") { confirming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    confirming = false
                    model.trashSelected()
                    licence.refresh()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 580)
        .background(Theme.stage)
    }

    /// Selecting a Finder copy and being told it frees its full size is the lie
    /// this app exists to stop telling.
    ///
    /// Every other figure in this view is what the volume gets back. This one is
    /// deliberately the occupied size, because the gap between the two *is* the
    /// message — quoting it anywhere else would just be answering one question
    /// twice.
    private var sharedNote: String? {
        let onDisk = model.selectedNodes.reduce(Int64(0)) { $0 + $1.physicalBytes }
        guard onDisk > model.selectedBytes else { return nil }
        return "\(humanBytes(onDisk)) on disk. \(humanBytes(onDisk - model.selectedBytes)) of that "
            + "is shared with copies you are keeping, so deleting this does not return it."
    }

    private var warning: String {
        switch model.selectionRisk {
        case .risky:
            "Some of this belongs to an app that is using it. That app may lose settings or have to set itself up again. Everything lands in the Trash, so Put Back undoes it."
        case .yours:
            "These are your own files. Nothing recreates them, but they go to the Trash rather than away, so Put Back undoes it."
        case .safe, .blocked:
            "The tools that made these will make them again. Everything lands in the Trash, so Put Back undoes it."
        }
    }
}

/// Long paths are unreadable at a glance, and the middle of one is never the
/// interesting part while a scan is running.
func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    let parts = short.split(separator: "/")
    guard parts.count > 5 else { return short }
    return (short.hasPrefix("~") ? "~/…/" : "/…/") + parts.suffix(3).joined(separator: "/")
}
