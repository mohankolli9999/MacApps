import SwiftUI
import ReclaimCore

enum Mode: String, CaseIterable {
    case storage = "Storage"
    case system = "System"
    case caches = "Caches"
    case history = "History"
}

struct ContentView: View {
    @State private var model = ScanModel()
    @State private var storage = StorageModel()
    @State private var systemStorage = SystemStorageModel()
    @State private var licence = LicenseModel()
    @State private var paused = true
    @State private var reviewing = false
    @State private var showingLicence = false
    @State private var chosen: Set<String> = []
    @State private var mode: Mode = .storage
    @State private var gated = !UserDefaults.standard.bool(forKey: "hasSeenAccessGate")
    @State private var access = FullDiskAccess.access

    var body: some View {
        Group {
            if gated {
                AccessGate(access: access) {
                    UserDefaults.standard.set(true, forKey: "hasSeenAccessGate")
                    gated = false
                    storage.scan()
                }
            } else {
                main
            }
        }
        .background(Theme.stage)
        .frame(minWidth: 880, minHeight: 580)
        // Granting the permission restarts nothing and notifies nobody, so the
        // only way to notice is to keep asking. Cheap: three directory reads.
        .task {
            while !Task.isCancelled {
                access = FullDiskAccess.access
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            switch mode {
            case .storage:
                StorageView(model: storage,
                            access: access,
                            licence: licence,
                            onRequestAccess: { NSWorkspace.shared.open(FullDiskAccess.settingsURL) },
                            onOpenLicence: { showingLicence = true })
            case .system:
                SystemView(model: systemStorage)
            case .caches:
                HStack(spacing: 0) {
                    stage
                    Divider().overlay(Theme.hairline)
                    InspectorView(row: model.selectedRow, model: model)
                }
                Divider().overlay(Theme.hairline)
                footer
            case .history:
                HistoryView(model: model)
            }
        }
        .task {
            model.scan()
            model.refreshHistory()
        }
        .task(id: model.isScanning) {
            // Let the tween finish, then stop the display link. A treemap that
            // keeps redrawing at 120Hz while nothing moves is just a battery leak.
            if model.isScanning {
                paused = false
            } else {
                try? await Task.sleep(for: .milliseconds(900))
                paused = true
            }
        }
        .sheet(isPresented: $reviewing) { review }
        .sheet(isPresented: $showingLicence) {
            LicenseSheet(model: licence) { showingLicence = false }
        }
    }

    /// Two treemaps rather than one. A single pool is proportionally honest and
    /// practically useless: one 8 GB cache you cannot touch takes the whole
    /// window and leaves the reclaimable mass an unclickable sliver. Splitting by
    /// what you can act on keeps area exact inside each group, and the captions
    /// carry the totals so the split never has to be inferred from area.
    private var stage: some View {
        GeometryReader { geometry in
            let captions: CGFloat = 60
            let usable = max(0, geometry.size.height - captions)
            VStack(spacing: 0) {
                caption("Can come back", model.reclaimable)
                TreemapView(rows: model.reclaimable, selection: $model.selection, paused: paused,
                            emptyMessage: model.isScanning
                                ? "Measuring."
                                : "Nothing here has a proven way back.")
                    .frame(height: usable * 0.55)

                caption("Stays put", model.locked)
                TreemapView(rows: model.locked, selection: $model.selection, paused: paused,
                            emptyMessage: model.isScanning ? "Measuring." : "Nothing is locked.")
                    .frame(height: usable * 0.45)
            }
        }
        .frame(minWidth: 420)
    }

    /// Area is the treemap's one honest channel, so a block worth a fraction of a
    /// percent legitimately renders sub-pixel. Padding it out would lie about
    /// size; saying so in words costs nothing and keeps the counts trustworthy.
    private func unrenderable(_ rows: [ScanModel.Row]) -> [ScanModel.Row] {
        let total = rows.reduce(0) { $0 + $1.reclaimableBytes }
        guard total > 0 else { return [] }
        return rows.filter { Double($0.reclaimableBytes) / Double(total) < 0.005 }
    }

    private func caption(_ title: String, _ rows: [ScanModel.Row]) -> some View {
        let hidden = unrenderable(rows)
        return HStack(spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.78))
            Text(humanBytes(rows.reduce(0) { $0 + $1.reclaimableBytes }))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
            if !hidden.isEmpty {
                Text(hidden.count == 1
                     ? "· \(hidden[0].displayName) is too small to draw (\(humanBytes(hidden[0].reclaimableBytes)))"
                     : "· \(hidden.count) are too small to draw")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.stageEdge)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var busy: Bool {
        switch mode {
        case .storage: storage.isScanning
        case .system: systemStorage.isReading
        case .caches: model.isScanning
        case .history: false
        }
    }

    private func refresh() {
        switch mode {
        case .storage: storage.scan()
        case .system: systemStorage.read()
        case .caches: model.scan()
        case .history: model.refreshHistory()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Disk Reclaim")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
                Text("Measuring")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .transition(.opacity)
            }

            Spacer()

            LicenseBadge(model: licence) { showingLicence = true }

            VStack(alignment: .trailing, spacing: -1) {
                Text(humanBytes(model.freeBytes))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("free").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }

            unitPicker

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.muted)
            .disabled(busy)
            .help(mode == .history ? "Re-read the log" : "Measure everything again")
        }
        .animation(.easeOut(duration: 0.2), value: busy)
        .padding(.leading, 82)   // clears the traffic lights
        .padding(.trailing, 16)
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            legendItem(.exact, "Free to refetch")
            legendItem(.costly, "Costs time")
            legendItem(.irreplaceable, "Cannot restore")

            Spacer()

            if let blocked = licence.blockedReason {
                Text(blocked).font(.system(size: 11)).foregroundStyle(Theme.warn)
            } else if let outcome = model.lastReclaim {
                Text(outcome).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }

            Text("\(humanBytes(model.reclaimableBytes)) reclaimable")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(model.reclaimable.isEmpty ? Theme.muted : Theme.ink)

            if licence.canReclaim {
                Button("Review…") { reviewing = true }
                    .disabled(model.reclaimable.isEmpty)
            } else {
                Button("Unlock to Reclaim…") { showingLicence = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// Both bases are in use on the same machine — Finder divides by 1000, `du`
    /// by 1024 — so whichever this app picks, someone is comparing it against
    /// the other one and finding a 7% discrepancy.
    private var unitPicker: some View {
        Menu {
            Picker("", selection: Binding(get: { Preferences.shared.byteFormat },
                                          set: { Preferences.shared.byteFormat = $0 })) {
                ForEach(ByteFormat.allCases) { Text($0.menuLabel).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(Preferences.shared.byteFormat == .decimal ? "GB" : "GiB")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.muted)
        .help("How sizes are counted")
    }

    private func legendItem(_ tier: Tier, _ caption: String) -> some View {
        HStack(spacing: 6) {
            LegendSwatch(tier: tier)
            Text(caption).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private var chosenBytes: Int64 {
        model.reclaimable.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Reclaim these caches?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Every one listed has a proven way back, recorded before anything is removed. Nothing else on this Mac is touched.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.reclaimable) { row in
                        reviewRow(row)
                        Divider().overlay(Theme.hairline.opacity(0.5))
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack(spacing: 12) {
                Text("\(humanBytes(chosenBytes)) selected")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel") { reviewing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Reclaim \(chosen.count) \(chosen.count == 1 ? "cache" : "caches")") {
                    let ids = chosen
                    reviewing = false
                    Task {
                        await model.reclaim(ids)
                        licence.refresh()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 580)
        .background(Theme.stage)
        // Keyed on the rows themselves: a rescan that lands while the sheet is
        // open invalidates any selection made against the old numbers.
        .task(id: model.reclaimable) { chosen = Set(model.reclaimable.map(\.id)) }
    }

    private func reviewRow(_ row: ScanModel.Row) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Toggle("", isOn: Binding(
                get: { chosen.contains(row.id) },
                set: { on in
                    if on { chosen.insert(row.id) } else { chosen.remove(row.id) }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(humanBytes(row.reclaimableBytes))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                Text(row.path)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                if let recipe = row.recipe {
                    // Prose is reassurance and stays quiet; a literal command is
                    // the thing you will actually run, so it gets full contrast.
                    Text(recipe.command)
                        .font(.system(size: 10.5,
                                      design: recipe.kind == .automatic ? .default : .monospaced))
                        .foregroundStyle(recipe.kind == .automatic
                                         ? Theme.muted
                                         : Theme.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }
}

/// Shows the surface channel on its own: hue is per-tool, so the legend must
/// speak only about recoverability.
struct LegendSwatch: View {
    let tier: Tier

    var body: some View {
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size)
            let shape = Path(roundedRect: frame, cornerRadius: 2)
            context.fill(shape, with: .color(Theme.ink.opacity(Theme.fillOpacity(for: tier))))

            switch tier {
            case .irreplaceable, .unknown:
                context.drawLayer { layer in
                    layer.clip(to: shape)
                    var lines = Path()
                    var x = -size.height
                    while x < size.width {
                        lines.move(to: CGPoint(x: x, y: size.height))
                        lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 4
                    }
                    layer.stroke(lines, with: .color(Theme.ink.opacity(0.55)), lineWidth: 1)
                }
            case .costly:
                context.stroke(shape, with: .color(Theme.ink.opacity(0.9)), lineWidth: 1)
            case .exact:
                break
            }
        }
        .frame(width: 11, height: 11)
    }
}
