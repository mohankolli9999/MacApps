import QuickLook
import SwiftUI
import ReclaimCore

struct StorageView: View {
    @Bindable var model: StorageModel
    let access: FullDiskAccess.Access
    let onRequestAccess: () -> Void

    @State private var hovered: String?
    @State private var focused: String?
    @State private var previewing: URL?
    @FocusState private var listFocused: Bool
    @State private var confirming = false
    @State private var paused = true
    /// Which footer counter has its list open, if any.
    @State private var opened: String?
    @State private var reviewing = false
    /// Which caches the review sheet has ticked. Its own state rather than the
    /// tray's, so closing the sheet without acting leaves the tray as it was.
    @State private var ticked: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            locationBar
            Divider().overlay(Theme.hairline)

            // Above the tree check on purpose. Every figure this screen is about
            // to show is suppressed by the snapshot, so the reason has to be on
            // screen before the numbers are, not after the user has drawn their
            // own conclusion about them.
            if !model.pinningSnapshots.isEmpty, !model.snapshotNoticeDismissed {
                snapshotBanner(model.pinningSnapshots)
            }

            if model.tree == nil {
                model.isScanning ? AnyView(opening) : AnyView(idle)
            } else {
                if model.isScanning { scanStrip }
                if !model.isScanning, let caches = model.caches,
                   !caches.findings.isEmpty, !model.cacheNoticeDismissed {
                    cacheBanner(caches)
                }
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
        // Polled, because nothing tells an app that free space moved. Emptying
        // the Trash, another app writing, a Time Machine snapshot expiring: all
        // of them change the number under a figure that would otherwise have
        // been read once at launch and never again.
        .task {
            while !Task.isCancelled {
                await model.refreshSpace()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $confirming) { confirmation }
        .sheet(isPresented: $reviewing) {
            if let caches = model.caches { cacheReview(caches) }
        }
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

            capacity

            if let here = model.current {
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16)

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

    /// The one true thing available before any walking happens, and the one
    /// thing still worth showing long after.
    ///
    /// A full scan is a minute or more and every frame of it used to be blank,
    /// which is indistinguishable from a hung app and is most of what "the app
    /// is slow" actually describes. This costs a syscall and answers the first
    /// question anyone opens the app with. It sits in the location bar and not
    /// on the waiting screen so that it survives the map arriving: the question
    /// "how much room have I got" does not stop being the point once there is
    /// something to look at — it is the reason the user is looking.
    ///
    /// Deliberately not adjusted by what is in the tray. The Trash is a folder
    /// on this same volume, so a gigabyte moved there frees nothing until the
    /// Trash is emptied, and a bar that filled back in as things were ticked
    /// would be promising space the disk does not have yet.
    @ViewBuilder private var capacity: some View {
        if let space = model.space {
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline.opacity(0.7))
                    Capsule().fill(Theme.ink.opacity(0.45))
                        .frame(width: 64 * min(1, Double(space.used) / Double(max(1, space.capacity))))
                }
                .frame(width: 64, height: 5)

                Text("\(humanBytes(space.used)) used · \(humanBytes(space.free)) free")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: space.free)
            }
            .help("\(model.root.name) holds \(humanBytes(space.capacity)) and has \(humanBytes(space.free)) left. Moving files to the Trash does not give the space back until the Trash is emptied.")
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

    // MARK: - Caches

    /// A snapshot keeps every block the volume held when it was taken, so files
    /// older than it free nothing when deleted. The scan reports that correctly
    /// — it is the one measurement here no competitor makes — but a disk that
    /// reads as almost entirely unreclaimable looks like a broken scan unless
    /// the screen says why.
    private func snapshotBanner(_ snapshots: [VolumeLedger.Snapshot]) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warn)
            Text(snapshots.count == 1
                 ? "A snapshot is holding this volume's older files"
                 : "\(snapshots.count) snapshots are holding this volume's older files")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.9))
            Text("Files it contains free nothing until it expires, usually within a day, so they read as reclaiming zero here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer()
            Button {
                model.snapshotNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Hide until the next scan")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.warn.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// Sits above the map rather than opening ahead of it. The map is what the
    /// user came for and what makes the number below believable; a screen that
    /// opened on this instead would be asking them to act on a figure they had
    /// not yet been shown the basis for.
    private func cacheBanner(_ caches: CacheSurvey) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.gain)
            Text("\(humanBytes(caches.floorBytes)) in \(caches.findings.count) browser and app caches")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.9))
            Text("These free up now and refill as you use the apps.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Spacer()
            Button("Review") {
                // Derived data arrives ticked and service worker storage does
                // not, which is the whole difference between the two groups.
                ticked = Set(caches.derived.map(\.id))
                reviewing = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.gain)
            Button {
                model.cacheNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Hide until the next scan")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.gain.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func cacheReview(_ caches: CacheSurvey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Browser and app caches")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Chromium is built into far more than browsers, and it keeps the same caches wherever it runs. These are the ones on this disk.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(spacing: 0) {
                    if !caches.derived.isEmpty {
                        cacheGroup("Safe to delete",
                                   note: "Pure derived data. Each app refetches or rebuilds it as you go.",
                                   findings: caches.derived,
                                   bytes: caches.derivedFloorBytes)
                    }
                    if !caches.offline.isEmpty {
                        cacheGroup("May hold offline data",
                                   note: "Service workers can store pages and queued writes for offline use. Check before deleting.",
                                   findings: caches.offline,
                                   bytes: caches.offlineFloorBytes)
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider().overlay(Theme.hairline)

            HStack(spacing: 12) {
                Text(tickedBytes(caches) == 0
                     ? "Nothing selected"
                     : "\(humanBytes(tickedBytes(caches))) from \(ticked.count) \(ticked.count == 1 ? "cache" : "caches")")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Cancel") { reviewing = false }
                    .keyboardShortcut(.cancelAction)
                // Deliberately hands these to the tray instead of deleting
                // them. The tray is the only place that knows everything picked
                // — here and off the map both — and deleting from this sheet
                // would quote a total that ignores the rest of it.
                Button("Add to selection") {
                    model.collect(caches.findings.filter { ticked.contains($0.id) })
                    // The notice has done its job once it has been acted on.
                    // Leaving it up would go on offering bytes that are already
                    // sitting in the tray underneath it.
                    model.cacheNoticeDismissed = true
                    reviewing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ticked.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 620)
        .background(Theme.stage)
    }

    private func tickedBytes(_ caches: CacheSurvey) -> Int64 {
        caches.findings
            .filter { ticked.contains($0.id) }
            .reduce(0) { $0 + $1.node.reclaimableBytes }
    }

    private func cacheGroup(_ title: String,
                            note: String,
                            findings: [CacheSurvey.Finding],
                            bytes: Int64) -> some View {
        let ids = Set(findings.map(\.id))
        let all = ids.isSubset(of: ticked)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Toggle(isOn: Binding(get: { all },
                                     set: { on in
                                         if on { ticked.formUnion(ids) } else { ticked.subtract(ids) }
                                     })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(humanBytes(bytes))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.stageEdge)

            ForEach(findings) { finding in
                HStack(spacing: 9) {
                    Toggle(isOn: Binding(get: { ticked.contains(finding.id) },
                                         set: { on in
                                             if on { ticked.insert(finding.id) }
                                             else { ticked.remove(finding.id) }
                                         })) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(finding.cache.owner)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text(finding.cache.contents)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                        }
                        Text(abbreviate(finding.node.url.path))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(Theme.muted.opacity(0.8))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(humanBytes(finding.node.reclaimableBytes))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider().overlay(Theme.hairline.opacity(0.4))
            }
        }
    }

    // MARK: - Listing

    private var listing: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.listing) { node in
                        row(node).id(node.id)
                        Divider().overlay(Theme.hairline.opacity(0.4))
                    }
                    if let extra = model.current?.unlistedBytes, extra > 0 {
                        remainderRow(extra)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.stageEdge.opacity(0.5))
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            // Without this the keys do nothing until the list is clicked, and a
            // keyboard user has no way to discover that a click is what is
            // missing. The list is the only thing on this screen worth driving
            // from the keyboard, so it starts with the focus.
            .onAppear { listFocused = true }
            .onKeyPress { press in handle(press, scroller: scroller) }
            // Descending keeps no focus: the row that had it is not on screen any
            // more, and carrying the index across would land on an unrelated file.
            .onChange(of: model.current?.id) { focused = nil }
        }
        .quickLookPreview($previewing)
    }

    /// One handler rather than a stack of `.onKeyPress(.upArrow)` modifiers,
    /// because ⌘⌫ has to be told apart from ⌫ and only the general form carries
    /// the modifiers. Anything not claimed here must return `.ignored` or it stops
    /// reaching the rest of the window.
    private func handle(_ press: KeyPress, scroller: ScrollViewProxy) -> KeyPress.Result {
        // Matched against the modifiers that change what a key means, rather than
        // against everything the event happens to carry. An arrow key arrives with
        // numeric-pad and function set and caps lock is a modifier like any other,
        // so an exact match against `[]` fires for none of them — and subtracting
        // the incidental ones instead is a list only as complete as the last
        // person to extend it, where the cost of missing a bit is that the whole
        // of keyboard navigation goes quietly dead.
        let modifiers = press.modifiers.intersection([.shift, .control, .option, .command])
        switch (press.key, modifiers) {
        case (.upArrow, []): moveFocus(by: -1, scroller: scroller)
        case (.downArrow, []): moveFocus(by: 1, scroller: scroller)
        case (.leftArrow, []):
            guard model.breadcrumb.count > 1 else { return .ignored }
            withAnimation(.easeOut(duration: 0.18)) { model.rise(to: model.breadcrumb.count - 1) }
        case (.rightArrow, []), (.return, []):
            guard let node = focusedNode, node.isExplorable else { return .ignored }
            withAnimation(.easeOut(duration: 0.18)) { model.open(node) }
        case (.space, []):
            guard let node = focusedNode else { return .ignored }
            preview(node)
        case (.delete, .command):
            guard let node = focusedNode, model.risk(of: node).isTrashable else { return .ignored }
            model.toggle(node)
        default:
            return .ignored
        }
        return .handled
    }

    private var focusedNode: StorageNode? {
        focused.flatMap { id in model.listing.first { $0.id == id } }
    }

    private func moveFocus(by step: Int, scroller: ScrollViewProxy) {
        let rows = model.listing
        guard !rows.isEmpty else { return }
        let next = focused.flatMap { id in rows.firstIndex { $0.id == id } }
            .map { min(rows.count - 1, max(0, $0 + step)) } ?? (step > 0 ? 0 : rows.count - 1)
        focused = rows[next].id
        scroller.scrollTo(rows[next].id, anchor: .center)
    }

    /// Space previews, except when previewing is the expensive thing on the
    /// screen. A cloud placeholder holds no local bytes, so Quick Look would fetch
    /// the whole file from the provider — and the app's own refusal to materialise
    /// placeholders cannot stop it, because the preview is drawn in another
    /// process. Saying what it would cost is more use than a preview anyway: the
    /// size is the reason the row is worth looking at.
    private func preview(_ node: StorageNode) {
        switch StorageSafety.preview(for: node.url) {
        case .allowed:
            previewing = node.url
        case .wouldDownload(let bytes):
            model.note("\(node.name) is stored in the cloud. Nothing of it is on this disk, and previewing it would download \(humanBytes(bytes)).")
        case .missing:
            model.note("\(node.name) is no longer there. Measure again to update the totals.")
        }
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
        .background(focused == node.id ? Theme.ink.opacity(0.10)
                    : hovered == node.id ? Theme.ink.opacity(0.05) : .clear)
        // A bar on the leading edge rather than a ring, so keyboard focus is
        // legible against the hover tint without competing with the risk hue the
        // row already spends colour on.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(focused == node.id ? Theme.ink.opacity(0.55) : .clear)
                .frame(width: 2)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
        .onTapGesture { focused = node.id }
        // Carries the key equivalents as much as the commands. The shortcuts work
        // on the focused row whether or not this menu is open; a right-click is
        // where someone finds out they exist.
        .contextMenu {
            Button("Quick Look") { focused = node.id; preview(node) }
                .keyboardShortcut(.space, modifiers: [])
            Button("Reveal in Finder") { model.reveal(node) }
            if node.isExplorable {
                Button("Open") { withAnimation(.easeOut(duration: 0.18)) { model.open(node) } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            if level.isTrashable {
                Divider()
                Button(model.selection.contains(node.id) ? "Deselect" : "Select for the Trash") {
                    model.toggle(node)
                }
                .keyboardShortcut(.delete, modifiers: .command)
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
                        // The repair rides along only when the probe actually
                        // came back denied — see `AccessGate.detail` for why it
                        // describes no pane state. Offered to someone whose
                        // access is fine, it would send them to undo a working
                        // grant over folders that were never going to be read.
                        note: access == .denied
                            ? "The scan was refused these, so their bytes are missing from every total above. Full Disk Access is almost always the reason. If Disk Reclaim is already listed there, remove it and add it again."
                            : "The scan was refused these, so their bytes are missing from every total above. Full Disk Access is almost always the reason.",
                        paths: model.unreadablePaths,
                        total: model.unreadableLocations,
                        tint: Theme.warn,
                        // The one route to the permission after the opening
                        // screen, and the user has to open this list to find
                        // it. An app that keeps a Grant Access button in front
                        // of someone who has already answered is nagging; one
                        // that offers it where they came asking why the folders
                        // are missing is answering the question.
                        action: ("Open Full Disk Access…", onRequestAccess))
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

            if let note = model.lastAction {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }

            if !model.selection.isEmpty {
                Text(model.isEstimating
                     ? "\(model.selection.count) selected · frees at least \(humanBytes(model.selectedBytes))"
                     : "\(model.selection.count) selected · frees \(humanBytes(model.selectedBytes))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }

            Button("Move to Trash…") { confirming = true }
                .disabled(model.selection.isEmpty)
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
                         tint: Color,
                         action: (title: String, run: () -> Void)? = nil) -> some View {
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
                if let action {
                    Divider().overlay(Theme.hairline)
                    Button(action.title) {
                        opened = nil
                        action.run()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
