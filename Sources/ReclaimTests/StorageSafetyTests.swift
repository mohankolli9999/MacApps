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

    t.section("Offline")

    // The product claim is that nothing leaves the machine. A promise in a README
    // rots; a test that fails the build when networking appears does not.
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
