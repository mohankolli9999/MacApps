import Foundation
import ReclaimCore

@MainActor func runStorageSafetyTests(_ t: Harness) {
    t.section("Trash")

    // Arbitrary files carry no restore recipe, so the Trash is their way back.
    // Deleting them outright would make the manifest's promise decorative.
    do {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("trashme-\(UUID().uuidString).bin")
        try! Data(count: 4096).write(to: file)

        let landed = try! Trash.put(file)
        t.expect(!FileManager.default.fileExists(atPath: file.path),
                 "the original is gone from its old location")
        t.expect(FileManager.default.fileExists(atPath: landed.path),
                 "the file still exists in the Trash, recoverable by Put Back")
        try? FileManager.default.removeItem(at: landed)
    }

    do {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-existed-\(UUID().uuidString)")
        var threw = false
        do { _ = try Trash.put(missing) } catch { threw = true }
        t.expect(threw, "trashing something that is not there is an error, not a silent success")
    }

    t.section("Storage risk")

    // The storage map lets the user pick anything, so the risk of each pick has
    // to be legible before the click, not explained after it.
    do {
        let home = URL(fileURLWithPath: NSHomeDirectory())

        t.equal(StorageSafety.risk(for: home.appending(path: "Library/Caches/pip/wheels")),
                .safe, "a cache is safe to remove")
        t.equal(StorageSafety.risk(for: home.appending(path: "code/app/node_modules")),
                .safe, "node_modules is safe to remove")
        t.equal(StorageSafety.risk(for: home.appending(path: "Documents/thesis.pdf")),
                .yours, "a document is yours to delete, and gone when it is gone")
        t.equal(StorageSafety.risk(for: home.appending(path: "Library/Containers/com.apple.Notes")),
                .risky, "app internals may break the app that owns them")

        // Trashing the folder itself is never what someone means from a disk map,
        // and macOS treats these as fixtures rather than ordinary directories.
        t.equal(StorageSafety.risk(for: home), .blocked, "your home folder is not a deletable item")
        t.equal(StorageSafety.risk(for: home.appending(path: "Documents")),
                .blocked, "a standard home folder is a fixture, not an item")
        t.equal(StorageSafety.risk(for: URL(fileURLWithPath: "/System/Library/Fonts")),
                .blocked, "the app will not trash anything outside your control")

        // A cache is a cache wherever it lives; that beats the folder it sits in.
        t.equal(StorageSafety.risk(for: home.appending(path: "Documents/proj/node_modules")),
                .safe, "a cache inside your documents is still a cache")

        t.expect(!StorageSafety.risk(for: home).isTrashable, "blocked means the button is off")
        t.expect(StorageSafety.risk(for: home.appending(path: "Downloads/big.dmg")).isTrashable,
                 "everything else can go to the Trash")
    }

    t.section("System integrity protection")

    // /Applications is inside the allowlist, so a path test alone waves through
    // the bundles Apple protects there and the app offers a delete the kernel
    // refuses. Discovered rather than named: a test pinned to Safari passes
    // vacuously on a host that has removed it, and the control below is what
    // stops the whole of /Applications being blocked to make this go green.
    do {
        let apps = URL(fileURLWithPath: "/Applications")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []
        let restricted = names.map { apps.appending(path: $0) }.first { isRestricted($0.path) }
        let ordinary = names.map { apps.appending(path: $0) }.first {
            !isRestricted($0.path) && $0.pathExtension == "app"
        }

        if let restricted {
            t.equal(StorageSafety.risk(for: restricted), .blocked,
                    "a SIP-protected bundle is not this app's to remove")
            // The flag is carried by the contents too, so the guard cannot stop
            // at the bundle: a user who opens one and ticks a framework inside
            // gets the same EPERM from a row that looked ordinary.
            t.equal(StorageSafety.risk(for: restricted.appending(path: "Contents")),
                    .blocked, "and neither is anything inside it")
        }
        if let ordinary {
            t.expect(StorageSafety.risk(for: ordinary).isTrashable,
                     "an app Apple does not protect is still the user's to remove")
        }
        t.expect(restricted != nil && ordinary != nil,
                 "both a protected and an unprotected app were found to test against")
    }

    t.section("Quick Look gate")

    // The app already refuses to materialise placeholders, and that refusal
    // cannot reach a preview: the policy is `IOPOL_SCOPE_PROCESS`, and Quick Look
    // draws in a system service that never inherited it. So the one syscall that
    // protects the whole scan protects nothing here, and pressing space on an
    // evicted row downloads it — on a machine the user opened this app to free.
    do {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString).txt")
        try! Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        t.equal(StorageSafety.preview(for: file), .allowed,
                "an ordinary local file previews")
        t.equal(StorageSafety.preview(for: file.appendingPathExtension("gone")), .missing,
                "a file that is not there is not a refusal that needs explaining")

        // SF_DATALESS needs root to set, so no fixture can be a real placeholder
        // and the decision is tested apart from the syscall that reads the flag.
        // The pair above is what holds the two halves together.
        t.equal(StorageSafety.preview(flags: 0, logicalBytes: 5), .allowed,
                "nothing set, nothing to stop")
        t.equal(StorageSafety.preview(flags: UInt32(SF_DATALESS), logicalBytes: 2_100_000_000),
                .wouldDownload(bytes: 2_100_000_000),
                "an evicted file quotes what previewing it would pull down")
        t.equal(StorageSafety.preview(flags: UInt32(SF_DATALESS) | UInt32(UF_COMPRESSED),
                                      logicalBytes: 64),
                .wouldDownload(bytes: 64),
                "and stays evicted when another flag is set alongside")
    }

    t.section("Browser caches")

    // Every Electron app ships Chromium, so Chromium's cache directory names
    // turn up far from the browsers a user would think to check — under Notion,
    // Postman, Teams, an antivirus client. Most of them sit in Application
    // Support rather than Caches, which is why the folder they are in cannot be
    // what identifies them.
    do {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library")
        func match(_ path: String) -> BrowserCache? {
            BrowserCache.match(library.appending(path: path))
        }

        t.equal(match("Caches/Google/Chrome/Default/Cache/Cache_Data")?.kind, .derived,
                "a web cache refills itself from the network")
        t.equal(match("Application Support/Claude/Code Cache")?.kind, .derived,
                "compiled scripts are recompiled on demand")
        t.equal(match("Application Support/Code/GPUCache")?.kind, .derived,
                "a GPU program cache is rebuilt by the driver")
        t.equal(match("Caches/Arc/User Data/Default/DawnWebGPUCache")?.kind, .derived,
                "shader caches are derived data under whichever name the engine uses")
        t.equal(match("Application Support/Vivaldi/component_crx_cache")?.kind, .derived,
                "downloaded components are fetched again when needed")

        // The one name here that is not purely derived. A service worker may
        // have put the only copy of an offline page or an unsent write in it,
        // so it is offered separately and never ticked for the user.
        t.equal(match("Application Support/Vivaldi/Default/Service Worker/CacheStorage")?.kind,
                .offline, "service worker storage can hold offline pages and queued writes")

        t.expect(match("Application Support/Notion/Partitions/notion/Cache") == nil,
                 "the folder holding a web cache is not itself one")
        t.expect(BrowserCache.match(URL(fileURLWithPath: NSHomeDirectory())
                    .appending(path: "code/engine/Code Cache")) == nil,
                 "a folder of the user's that happens to share the name is not a browser cache")
    }

    // The review list is unreadable if fifteen rows all say CacheStorage, so
    // each finding has to name the app it belongs to.
    do {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library")
        func owner(_ path: String) -> String? {
            BrowserCache.match(library.appending(path: path))?.owner
        }

        t.equal(owner("Caches/Google/Chrome/Default/Cache/Cache_Data"), "Google",
                "the folder under Caches names the app")
        t.equal(owner("Application Support/Notion Calendar/Cache/Cache_Data"), "Notion Calendar",
                "an app name with a space in it survives intact")
        t.equal(owner("Application Support/com.operasoftware.OperaGX/Service Worker/CacheStorage"),
                "OperaGX", "a bundle identifier is shown as a name, not as reverse DNS")
        t.equal(owner("Containers/com.microsoft.teams2/Data/Library/Caches/Microsoft/MSTeams/Cache/Cache_Data"),
                "Microsoft",
                "a sandboxed app is named from inside its container, not by the container")
    }

    // What the banner counts and what the review sheet lists, taken off the tree
    // the scan already built rather than by walking the disk a second time.
    do {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library")
        // Physical and reclaimable differ throughout, because the banner claims
        // space the user gets back rather than space the treemap draws, and a
        // fixture where the two agree cannot tell which one it reported.
        func dir(_ url: URL, _ bytes: Int64, _ children: [StorageNode] = []) -> StorageNode {
            StorageNode(url: url, name: url.lastPathComponent, physicalBytes: bytes,
                        reclaimableBytes: bytes - 100, isDirectory: true, children: children,
                        unlistedBytes: 0)
        }

        let webCache = library.appending(path: "Caches/Google/Chrome/Default/Cache/Cache_Data")
        let codeCache = library.appending(path: "Caches/Google/Chrome/Default/Code Cache")
        let workers = library.appending(path: "Application Support/Vivaldi/Default/Service Worker/CacheStorage")
        let tree = dir(library, 5_000, [
            dir(library.appending(path: "Caches"), 1_200, [
                dir(webCache, 900), dir(codeCache, 300),
            ]),
            dir(library.appending(path: "Application Support"), 1_700, [
                // A cache name nested inside a matched directory. Reporting it
                // as well would count its bytes twice and offer the user a row
                // that vanishes when they tick the one above it.
                dir(workers, 1_700, [dir(workers.appending(path: "Cache_Data"), 400)]),
            ]),
            dir(library.appending(path: "Mail"), 2_100),
        ])

        let survey = CacheSurvey(of: tree)
        t.equal(survey.findings.count, 3, "three caches on a tree that holds three")
        t.equal(survey.floorBytes, 2_600,
                "the banner counts what the user gets back, not what the map draws")
        t.equal(survey.derived.map(\.node.name).sorted(), ["Cache_Data", "Code Cache"],
                "pure derived data is what gets ticked")
        t.equal(survey.offline.map(\.node.name), ["CacheStorage"],
                "service worker storage is held apart from it")
        t.equal(survey.derivedFloorBytes, 1_000, "each group carries its own subtotal")
        t.expect(survey.findings.allSatisfy { $0.node.url != workers.appending(path: "Cache_Data") },
                 "a matched directory is taken whole, so nothing inside it is offered again")
        t.equal(survey.derived.map(\.node.physicalBytes), [900, 300],
                "findings arrive largest first, because that is the order worth reviewing")
    }

    do {
        let empty = StorageNode(url: URL(fileURLWithPath: NSHomeDirectory()), name: "home",
                                physicalBytes: 0, reclaimableBytes: 0, isDirectory: true,
                                children: [], unlistedBytes: 0)
        t.expect(CacheSurvey(of: empty).findings.isEmpty,
                 "a tree with no caches produces no banner")
    }

    // The tier the confirmation sheet reads has to agree with the tick the
    // review sheet set, or the app argues with itself mid-delete.
    do {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library")
        t.equal(StorageSafety.risk(for: library.appending(path: "Application Support/Claude/Code Cache")),
                .safe, "a derived cache is safe wherever the app decided to keep it")
        t.equal(StorageSafety.risk(for: library.appending(path: "Caches/Vivaldi/Default/Service Worker/CacheStorage")),
                .risky, "service worker storage is not waved through for sitting under Caches")
    }

    t.section("Offline")

    // The product claim is that nothing leaves the machine. A promise in a README
    // rots; a test that fails the build when networking appears does not.
    //
    // The catch, if you are here because this went red and you cannot see why:
    // it matches bare literals anywhere in a shipped .swift file, comments and
    // user-facing strings included. So the guarantee eats its own documentation
    // — the panel in the app that tells people about this test cannot name the
    // symbols it is describing, and has to say what they are in prose. Keep it
    // that way rather than exempting a file: an exemption is a hole, and prose
    // is what a non-developer reading that panel needed anyway.
    do {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shipped = ["Sources/ReclaimCore", "Sources/DiskReclaim", "Sources/reclaim"]
        let banned = ["URLSession", "NSURLConnection", "NWConnection", "CFSocket", "import Network"]

        var offenders: [String] = []
        for area in shipped {
            let dir = root.appendingPathComponent(area)
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            for case let file as URL in files ?? .init() where file.pathExtension == "swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for symbol in banned where text.contains(symbol) {
                    offenders.append("\(file.lastPathComponent): \(symbol)")
                }
            }
        }
        t.expect(offenders.isEmpty, "no shipped source references networking \(offenders)")
    }
}

/// Deliberately duplicates the kernel check rather than calling the guard under
/// test: asking `StorageSafety` which bundles are protected would make a deleted
/// guard report that there is nothing to protect, and the assertions above would
/// pass by finding no subject at all.
private func isRestricted(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_flags & UInt32(SF_RESTRICTED) != 0
}
