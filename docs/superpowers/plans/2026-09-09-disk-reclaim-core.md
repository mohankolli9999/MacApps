# Disk Reclaim Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `ReclaimCore` library and a `reclaim` CLI that reclaims developer and AI-model disk artefacts, never deleting anything whose restore recipe has not just been validated against reality.

**Architecture:** A SwiftPM package with one library target (`ReclaimCore`), one CLI executable (`reclaim`), and one test executable (`ReclaimTests`). Data flows Scanner/Probes → Classifier → Validator → Executor → Manifest, with the Restore engine replaying recipes from the manifest. The catalogue is JSON data, not code, so new artefact types ship without touching Swift.

**Tech Stack:** Swift 6.2, SwiftPM, Foundation only — no third-party dependencies. macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-09-disk-reclaim-design.md`

## Global Constraints

- **Swift tools version 6.0**, `platforms: [.macOS(.v14)]`.
- **No third-party dependencies.** Foundation and Darwin only.
- **XCTest and swift-testing are unavailable** in this environment (verified: both fail to import under Command Line Tools). Tests are plain functions in the `ReclaimTests` executable target, run via `swift run -q ReclaimTests`, exiting non-zero on failure.
- **Swift 6 strict concurrency is on.** Mutable test state must be `@MainActor`-isolated; see the harness in Task 1.
- **No Xcode.** `swift build`, `swift run` only. Never emit `xcodebuild` commands.
- **Nothing in `Sources/` may delete a file unless a `Recipe` marked `.proven` was returned by a validator in the same run.** This is the product guarantee; a violation is a release blocker, not a bug.
- **Default tier ceiling for automatic action is `.costly`.** `.irreplaceable` and `.unknown` are never actioned without explicit per-item consent.
- Test fixtures are created under `FileManager.default.temporaryDirectory` and always torn down. **No test may write outside the temporary directory.**

---

### Task 1: Package scaffold, test harness, core types

**Files:**
- Create: `Package.swift`
- Create: `Sources/ReclaimCore/Tier.swift`
- Create: `Sources/ReclaimCore/Recipe.swift`
- Create: `Sources/ReclaimCore/Artefact.swift`
- Create: `Sources/ReclaimTests/Harness.swift`
- Create: `Sources/ReclaimTests/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Tier` (`.exact`/`.costly`/`.irreplaceable`/`.unknown`, `Comparable`), `Cost`, `Recipe`, `Artefact`, and the test harness `Harness.expect(_:_:)` / `Harness.report()`.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/Harness.swift`:

```swift
import Foundation

@MainActor final class Harness {
    private var failures = 0
    private var total = 0

    func expect(_ condition: Bool, _ label: String) {
        total += 1
        if condition {
            print("  ok   \(label)")
        } else {
            print("  FAIL \(label)")
            failures += 1
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        expect(actual == expected, "\(label) (got \(actual), want \(expected))")
    }

    func section(_ name: String) { print("\n\(name)") }

    func report() -> Int32 {
        print(failures == 0 ? "\nPASS \(total)/\(total)" : "\nFAILED \(failures)/\(total)")
        return failures == 0 ? 0 : 1
    }
}
```

Create `Sources/ReclaimTests/main.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runAll() -> Int32 {
    let t = Harness()

    t.section("Tier ordering")
    t.expect(Tier.exact < Tier.costly, "exact sorts before costly")
    t.expect(Tier.costly < Tier.irreplaceable, "costly sorts before irreplaceable")
    t.expect(Tier.irreplaceable < Tier.unknown, "irreplaceable sorts before unknown")
    t.expect(Tier.exact <= .costly, "action ceiling admits exact and costly")
    t.expect(!(Tier.irreplaceable <= .costly), "action ceiling excludes irreplaceable")

    t.section("Recipe")
    let r = Recipe(kind: .ollamaPull,
                   command: "ollama pull llama3:8b",
                   parameters: ["digest": "sha256:abc"],
                   cost: Cost(seconds: nil, bytesToRefetch: 4_700_000_000))
    t.equal(r.kind, .ollamaPull, "recipe kind round-trips")
    t.equal(r.parameters["digest"], "sha256:abc", "recipe parameters retained")

    t.section("Artefact")
    let a = Artefact(id: "ollama.models",
                     path: URL(fileURLWithPath: "/tmp/x"),
                     logicalBytes: 100,
                     physicalBytes: 90,
                     tier: .exact,
                     recipe: r)
    t.equal(a.tier, .exact, "artefact carries tier")
    t.expect(a.recipe != nil, "artefact carries recipe")

    return t.report()
}

exit(MainActor.assumeIsolated { runAll() })
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `error: no such module 'ReclaimCore'` (the package does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskReclaim",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReclaimCore"),
        .executableTarget(name: "reclaim", dependencies: ["ReclaimCore"]),
        .executableTarget(name: "ReclaimTests", dependencies: ["ReclaimCore"]),
    ]
)
```

Create `Sources/ReclaimCore/Tier.swift`:

```swift
/// How an artefact can be brought back, which determines what may be done to it.
public enum Tier: String, Codable, Sendable, CaseIterable, Comparable {
    /// Restores byte-identical from a recipe.
    case exact
    /// Regenerates deterministically, at a measured time cost.
    case costly
    /// No recipe exists. Never actioned automatically.
    case irreplaceable
    /// Not present in the catalogue. Never touched.
    case unknown

    private var rank: Int {
        switch self {
        case .exact: 0
        case .costly: 1
        case .irreplaceable: 2
        case .unknown: 3
        }
    }

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rank < rhs.rank }

    /// The highest tier that may be actioned without explicit per-item consent.
    public static let automaticCeiling: Tier = .costly
}
```

Create `Sources/ReclaimCore/Recipe.swift`:

```swift
/// What restoring an artefact costs the user.
public struct Cost: Codable, Sendable, Equatable {
    public var seconds: Int?
    public var bytesToRefetch: Int64?

    public init(seconds: Int? = nil, bytesToRefetch: Int64? = nil) {
        self.seconds = seconds
        self.bytesToRefetch = bytesToRefetch
    }

    public static let free = Cost()
}

/// The proof that an artefact can be recreated after deletion.
public struct Recipe: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case ollamaPull
        case huggingFaceDownload
        case npmCleanInstall
        case homebrewFetch
        case pipDownload
        case rebuild
    }

    public var kind: Kind
    /// The exact command that restores this artefact, shown to the user verbatim.
    public var command: String
    public var parameters: [String: String]
    public var cost: Cost

    public init(kind: Kind, command: String, parameters: [String: String] = [:], cost: Cost = .free) {
        self.kind = kind
        self.command = command
        self.parameters = parameters
        self.cost = cost
    }
}
```

Create `Sources/ReclaimCore/Artefact.swift`:

```swift
import Foundation

/// A discovered, classified chunk of reclaimable disk.
public struct Artefact: Sendable, Equatable {
    /// Catalogue entry id, e.g. "ollama.models".
    public var id: String
    public var path: URL
    /// Sum of file sizes.
    public var logicalBytes: Int64
    /// Blocks actually allocated, with hardlinks counted once.
    public var physicalBytes: Int64
    public var tier: Tier
    public var recipe: Recipe?

    public init(id: String, path: URL, logicalBytes: Int64, physicalBytes: Int64, tier: Tier, recipe: Recipe? = nil) {
        self.id = id
        self.path = path
        self.logicalBytes = logicalBytes
        self.physicalBytes = physicalBytes
        self.tier = tier
        self.recipe = recipe
    }
}
```

Create `Sources/reclaim/main.swift` so the executable target compiles:

```swift
print("reclaim: no commands yet")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS 9/9

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources
git commit -m "feat: package scaffold, core types, test harness"
```

---

### Task 2: Scanner with hardlink-correct accounting

**Files:**
- Create: `Sources/ReclaimCore/Scanner.swift`
- Create: `Sources/ReclaimTests/ScannerTests.swift`
- Modify: `Sources/ReclaimTests/main.swift` (call `runScannerTests(t)`)

**Interfaces:**
- Consumes: nothing from Task 1 beyond the harness.
- Produces: `Scanner.measure(_ url: URL) throws -> Measurement`, where `Measurement` has `logicalBytes: Int64`, `physicalBytes: Int64`, `fileCount: Int`.

**Known limitation, deliberate:** this measures hardlinks correctly by deduplicating on `(st_dev, st_ino)`. True APFS *clone* accounting — where distinct inodes share blocks — needs block-level introspection and is out of scope for v1. The spec's clone claim is reduced to hardlinks here; record it in the README rather than overclaim.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/ScannerTests.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runScannerTests(_ t: Harness) {
    t.section("Scanner")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("reclaim-scan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let sub = root.appendingPathComponent("nested")
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

    let a = root.appendingPathComponent("a.bin")
    let b = sub.appendingPathComponent("b.bin")
    try? Data(repeating: 0x41, count: 10_000).write(to: a)
    try? Data(repeating: 0x42, count: 20_000).write(to: b)

    guard let m = try? Scanner.measure(root) else {
        t.expect(false, "scanner returned a measurement")
        return
    }
    t.equal(m.fileCount, 2, "counts files recursively")
    t.equal(m.logicalBytes, 30_000, "sums logical bytes")
    t.expect(m.physicalBytes >= 30_000, "physical bytes at least logical")

    // A hardlink must not be double-counted.
    let link = root.appendingPathComponent("a-link.bin")
    try? FileManager.default.linkItem(at: a, to: link)

    guard let m2 = try? Scanner.measure(root) else {
        t.expect(false, "scanner handled hardlink")
        return
    }
    t.equal(m2.fileCount, 2, "hardlink is not counted as an extra file")
    t.equal(m2.physicalBytes, m.physicalBytes, "hardlink adds no physical bytes")

    // A missing path is an error, not a zero.
    let missing = root.appendingPathComponent("does-not-exist")
    var threw = false
    do { _ = try Scanner.measure(missing) } catch { threw = true }
    t.expect(threw, "missing path throws rather than reporting zero")
}
```

Add to `Sources/ReclaimTests/main.swift`, immediately before `return t.report()`:

```swift
    runScannerTests(t)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `cannot find 'Scanner' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ReclaimCore/Scanner.swift`:

```swift
import Foundation

public enum ScanError: Error, Equatable {
    case notFound(String)
    case unreadable(String)
}

public enum Scanner {
    public struct Measurement: Sendable, Equatable {
        public var logicalBytes: Int64
        public var physicalBytes: Int64
        public var fileCount: Int

        public static let zero = Measurement(logicalBytes: 0, physicalBytes: 0, fileCount: 0)
    }

    private struct INode: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// Recursively measure a directory, counting each inode exactly once.
    public static func measure(_ url: URL) throws -> Measurement {
        var probe = stat()
        guard lstat(url.path, &probe) == 0 else {
            throw ScanError.notFound(url.path)
        }

        var seen = Set<INode>()
        var result = Measurement.zero

        func account(_ path: String) {
            var s = stat()
            guard lstat(path, &s) == 0 else { return }
            guard (s.st_mode & S_IFMT) == S_IFREG else { return }
            let key = INode(device: s.st_dev, inode: s.st_ino)
            guard seen.insert(key).inserted else { return }
            result.fileCount += 1
            result.logicalBytes += Int64(s.st_size)
            result.physicalBytes += Int64(s.st_blocks) * 512
        }

        if (probe.st_mode & S_IFMT) == S_IFREG {
            account(url.path)
            return result
        }

        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles.subtracting(.skipsHiddenFiles)]
        ) else {
            throw ScanError.unreadable(url.path)
        }

        for case let child as URL in e {
            account(child.path)
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS, including the six scanner assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: scanner with hardlink-correct byte accounting"
```

---

### Task 3: Catalogue loaded from JSON

**Files:**
- Create: `Sources/ReclaimCore/Catalogue.swift`
- Create: `Sources/ReclaimCore/Resources/catalogue.json`
- Create: `Sources/ReclaimTests/CatalogueTests.swift`
- Modify: `Package.swift` (add the resource to the `ReclaimCore` target)
- Modify: `Sources/ReclaimTests/main.swift`

**Interfaces:**
- Consumes: `Tier` from Task 1.
- Produces: `CatalogueEntry` (fields `id`, `displayName`, `path`, `tier`, `recipeKind`, `validator`), `Catalogue.load(from:)`, `Catalogue.bundled()`, `Catalogue.entries: [CatalogueEntry]`.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/CatalogueTests.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runCatalogueTests(_ t: Harness) {
    t.section("Catalogue")

    let json = """
    {
      "version": 1,
      "entries": [
        { "id": "ollama.models", "displayName": "Ollama models",
          "path": "~/.ollama/models", "tier": "exact",
          "recipeKind": "ollamaPull", "validator": "ollama" },
        { "id": "docker.volumes", "displayName": "Docker named volumes",
          "path": "~/Library/Containers/com.docker.docker/Data/vms",
          "tier": "irreplaceable", "validator": "none" }
      ]
    }
    """.data(using: .utf8)!

    guard let cat = try? Catalogue.load(from: json) else {
        t.expect(false, "catalogue parses")
        return
    }
    t.equal(cat.entries.count, 2, "loads all entries")
    t.equal(cat.entries[0].tier, .exact, "parses tier")
    t.equal(cat.entries[0].recipeKind, .ollamaPull, "parses recipe kind")
    t.expect(cat.entries[1].recipeKind == nil, "irreplaceable entry has no recipe kind")
    t.expect(cat.entries[0].expandedPath.hasPrefix(NSHomeDirectory()), "expands tilde")
    t.expect(!cat.entries[0].expandedPath.contains("~"), "no tilde remains after expansion")

    t.expect(cat.entry(id: "ollama.models") != nil, "lookup by id finds entry")
    t.expect(cat.entry(id: "nope") == nil, "lookup by unknown id returns nil")

    // The shipped catalogue must be valid and cover the measured categories.
    guard let bundled = try? Catalogue.bundled() else {
        t.expect(false, "bundled catalogue loads")
        return
    }
    for required in ["ollama.models", "huggingface.hub", "npm.cache", "xcode.deriveddata", "docker.volumes"] {
        t.expect(bundled.entry(id: required) != nil, "bundled catalogue has \(required)")
    }
    t.equal(bundled.entry(id: "docker.volumes")?.tier, .irreplaceable, "docker volumes are irreplaceable")
    t.equal(bundled.entry(id: "xcode.deriveddata")?.tier, .costly, "DerivedData is costly, not exact")
}
```

Add `runCatalogueTests(t)` to `main.swift` before `return t.report()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `cannot find 'Catalogue' in scope`.

- [ ] **Step 3: Write minimal implementation**

In `Package.swift`, change the `ReclaimCore` target to:

```swift
        .target(name: "ReclaimCore", resources: [.process("Resources")]),
```

Create `Sources/ReclaimCore/Resources/catalogue.json`:

```json
{
  "version": 1,
  "entries": [
    { "id": "ollama.models", "displayName": "Ollama models",
      "path": "~/.ollama/models", "tier": "exact",
      "recipeKind": "ollamaPull", "validator": "ollama" },
    { "id": "huggingface.hub", "displayName": "Hugging Face cache",
      "path": "~/.cache/huggingface/hub", "tier": "exact",
      "recipeKind": "huggingFaceDownload", "validator": "huggingface" },
    { "id": "lmstudio.models", "displayName": "LM Studio models",
      "path": "~/.lmstudio/models", "tier": "exact",
      "recipeKind": "huggingFaceDownload", "validator": "huggingface" },
    { "id": "npm.cache", "displayName": "npm cache",
      "path": "~/.npm/_cacache", "tier": "exact",
      "recipeKind": "npmCleanInstall", "validator": "alwaysProven" },
    { "id": "homebrew.cache", "displayName": "Homebrew download cache",
      "path": "~/Library/Caches/Homebrew", "tier": "exact",
      "recipeKind": "homebrewFetch", "validator": "alwaysProven" },
    { "id": "pip.cache", "displayName": "pip cache",
      "path": "~/Library/Caches/pip", "tier": "exact",
      "recipeKind": "pipDownload", "validator": "alwaysProven" },
    { "id": "xcode.deriveddata", "displayName": "Xcode DerivedData",
      "path": "~/Library/Developer/Xcode/DerivedData", "tier": "costly",
      "recipeKind": "rebuild", "validator": "alwaysProven" },
    { "id": "gradle.caches", "displayName": "Gradle caches",
      "path": "~/.gradle/caches", "tier": "costly",
      "recipeKind": "rebuild", "validator": "alwaysProven" },
    { "id": "docker.volumes", "displayName": "Docker named volumes",
      "path": "~/Library/Containers/com.docker.docker/Data/vms",
      "tier": "irreplaceable", "validator": "none" }
  ]
}
```

Create `Sources/ReclaimCore/Catalogue.swift`:

```swift
import Foundation

public struct CatalogueEntry: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var path: String
    public var tier: Tier
    public var recipeKind: Recipe.Kind?
    public var validator: String

    /// `path` with a leading tilde resolved against the current home directory.
    public var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }
}

public struct Catalogue: Codable, Sendable {
    public var version: Int
    public var entries: [CatalogueEntry]

    public func entry(id: String) -> CatalogueEntry? {
        entries.first { $0.id == id }
    }

    public static func load(from data: Data) throws -> Catalogue {
        try JSONDecoder().decode(Catalogue.self, from: data)
    }

    public static func bundled() throws -> Catalogue {
        guard let url = Bundle.module.url(forResource: "catalogue", withExtension: "json") else {
            throw ScanError.notFound("catalogue.json")
        }
        return try load(from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS, including all catalogue assertions.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources
git commit -m "feat: JSON-backed artefact catalogue with v1 entries"
```

---

### Task 4: Classifier with unknown-is-untouchable default

**Files:**
- Create: `Sources/ReclaimCore/Classifier.swift`
- Create: `Sources/ReclaimTests/ClassifierTests.swift`
- Modify: `Sources/ReclaimTests/main.swift`

**Interfaces:**
- Consumes: `Catalogue`, `CatalogueEntry`, `Artefact`, `Tier`, `Scanner.Measurement`.
- Produces: `Classifier(catalogue:)`, `Classifier.classify(path:measurement:) -> Artefact`.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/ClassifierTests.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runClassifierTests(_ t: Harness) {
    t.section("Classifier")

    let json = """
    {
      "version": 1,
      "entries": [
        { "id": "npm.cache", "displayName": "npm cache", "path": "/fixture/.npm/_cacache",
          "tier": "exact", "recipeKind": "npmCleanInstall", "validator": "alwaysProven" }
      ]
    }
    """.data(using: .utf8)!
    let cat = try! Catalogue.load(from: json)
    let c = Classifier(catalogue: cat)
    let m = Scanner.Measurement(logicalBytes: 500, physicalBytes: 512, fileCount: 3)

    let known = c.classify(path: URL(fileURLWithPath: "/fixture/.npm/_cacache"), measurement: m)
    t.equal(known.id, "npm.cache", "known path maps to catalogue id")
    t.equal(known.tier, .exact, "known path takes catalogue tier")
    t.equal(known.logicalBytes, 500, "measurement carried through")

    let stranger = c.classify(path: URL(fileURLWithPath: "/fixture/my-thesis"), measurement: m)
    t.equal(stranger.tier, .unknown, "unrecognised path is unknown, never actionable")
    t.expect(stranger.recipe == nil, "unknown artefact has no recipe")
    t.expect(!(stranger.tier <= Tier.automaticCeiling), "unknown is above the automatic ceiling")

    // A path *inside* a catalogued directory belongs to that entry.
    let child = c.classify(path: URL(fileURLWithPath: "/fixture/.npm/_cacache/index-v5"), measurement: m)
    t.equal(child.id, "npm.cache", "descendant path inherits the catalogue entry")

    // A path that merely shares a prefix string must not match.
    let impostor = c.classify(path: URL(fileURLWithPath: "/fixture/.npm/_cacache-backup"), measurement: m)
    t.equal(impostor.tier, .unknown, "sibling with shared prefix does not match")
}
```

Add `runClassifierTests(t)` to `main.swift`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `cannot find 'Classifier' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ReclaimCore/Classifier.swift`:

```swift
import Foundation

public struct Classifier: Sendable {
    private let catalogue: Catalogue

    public init(catalogue: Catalogue) {
        self.catalogue = catalogue
    }

    /// Map a measured path onto a catalogue entry. Anything unrecognised is
    /// `.unknown`, which is never actionable.
    public func classify(path: URL, measurement: Scanner.Measurement) -> Artefact {
        let target = path.standardizedFileURL.path

        let match = catalogue.entries.first { entry in
            let base = entry.expandedPath
            return target == base || target.hasPrefix(base + "/")
        }

        guard let entry = match else {
            return Artefact(id: "unknown",
                            path: path,
                            logicalBytes: measurement.logicalBytes,
                            physicalBytes: measurement.physicalBytes,
                            tier: .unknown)
        }

        return Artefact(id: entry.id,
                        path: path,
                        logicalBytes: measurement.logicalBytes,
                        physicalBytes: measurement.physicalBytes,
                        tier: entry.tier)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS, including all seven classifier assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: classifier treating unrecognised paths as untouchable"
```

---

### Task 5: Validators and the downgrade rule

**Files:**
- Create: `Sources/ReclaimCore/Validator.swift`
- Create: `Sources/ReclaimTests/ValidatorTests.swift`
- Modify: `Sources/ReclaimTests/main.swift`

**Interfaces:**
- Consumes: `Artefact`, `Recipe`, `Tier`, `CatalogueEntry`.
- Produces: `ValidationResult` (`.proven(Recipe)` / `.unproven(reason: String)`), protocol `RecipeValidator { func validate(_ artefact: Artefact) async -> ValidationResult }`, `AlwaysProvenValidator`, `NeverProvenValidator`, `CommandValidator`, and `ValidationRegistry.validator(named:) -> RecipeValidator`.
- Produces: `func applyValidation(_ artefact: Artefact, _ result: ValidationResult) -> Artefact` — the downgrade rule.

**This task implements the product guarantee.** A failed validation must downgrade the artefact to `.irreplaceable`, never proceed.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/ValidatorTests.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runValidatorTests(_ t: Harness) {
    t.section("Validator")

    let artefact = Artefact(id: "ollama.models",
                            path: URL(fileURLWithPath: "/fixture/models"),
                            logicalBytes: 1000, physicalBytes: 1024, tier: .exact)

    let proven = ValidationResult.proven(
        Recipe(kind: .ollamaPull, command: "ollama pull llama3:8b"))
    let ok = applyValidation(artefact, proven)
    t.equal(ok.tier, .exact, "proven artefact keeps its tier")
    t.expect(ok.recipe != nil, "proven artefact gains a recipe")
    t.expect(ok.tier <= Tier.automaticCeiling, "proven artefact is actionable")

    let failed = ValidationResult.unproven(reason: "ollama daemon unreachable")
    let downgraded = applyValidation(artefact, failed)
    t.equal(downgraded.tier, .irreplaceable, "unproven artefact downgrades to irreplaceable")
    t.expect(downgraded.recipe == nil, "unproven artefact carries no recipe")
    t.expect(!(downgraded.tier <= Tier.automaticCeiling), "unproven artefact is not actionable")

    // A costly artefact that fails validation also downgrades — no exceptions.
    let costly = Artefact(id: "xcode.deriveddata", path: URL(fileURLWithPath: "/fixture/dd"),
                          logicalBytes: 1, physicalBytes: 1, tier: .costly)
    t.equal(applyValidation(costly, failed).tier, .irreplaceable,
            "costly artefact downgrades on failure too")

    t.section("Validator registry")
    let always = ValidationRegistry.validator(named: "alwaysProven", recipeKind: .npmCleanInstall)
    let never = ValidationRegistry.validator(named: "none", recipeKind: nil)
    t.expect(always != nil, "alwaysProven validator resolves")
    t.expect(never != nil, "none validator resolves")

    // An unrecognised validator name must not silently pass.
    t.expect(ValidationRegistry.validator(named: "bogus", recipeKind: nil) == nil,
             "unknown validator name resolves to nil, not a permissive default")
}

func runAsyncValidatorTests(_ t: Harness) async {
    await t.section("Validator behaviour")

    let artefact = Artefact(id: "npm.cache", path: URL(fileURLWithPath: "/fixture/npm"),
                            logicalBytes: 1, physicalBytes: 1, tier: .exact)

    let always = AlwaysProvenValidator(recipe: Recipe(kind: .npmCleanInstall, command: "npm ci"))
    if case .proven = await always.validate(artefact) {
        await t.expect(true, "AlwaysProvenValidator proves")
    } else {
        await t.expect(false, "AlwaysProvenValidator proves")
    }

    let never = NeverProvenValidator(reason: "no recipe exists")
    if case .unproven(let reason) = await never.validate(artefact) {
        await t.equal(reason, "no recipe exists", "NeverProvenValidator reports its reason")
    } else {
        await t.expect(false, "NeverProvenValidator refuses")
    }

    // A command validator whose command does not exist must be unproven.
    let missing = CommandValidator(executable: "/usr/bin/definitely-not-a-real-binary",
                                   arguments: [],
                                   recipe: Recipe(kind: .ollamaPull, command: "ollama pull x"))
    if case .unproven = await missing.validate(artefact) {
        await t.expect(true, "CommandValidator is unproven when the tool is absent")
    } else {
        await t.expect(false, "CommandValidator is unproven when the tool is absent")
    }

    // A command validator that succeeds must be proven.
    let present = CommandValidator(executable: "/bin/echo", arguments: ["ok"],
                                   recipe: Recipe(kind: .ollamaPull, command: "ollama pull x"))
    if case .proven = await present.validate(artefact) {
        await t.expect(true, "CommandValidator is proven when the command succeeds")
    } else {
        await t.expect(false, "CommandValidator is proven when the command succeeds")
    }
}
```

Change `main.swift` to run the async suite. Replace its body with:

```swift
import Foundation
import ReclaimCore

@MainActor func runAll() async -> Int32 {
    let t = Harness()

    t.section("Tier ordering")
    t.expect(Tier.exact < Tier.costly, "exact sorts before costly")
    t.expect(Tier.costly < Tier.irreplaceable, "costly sorts before irreplaceable")
    t.expect(Tier.irreplaceable < Tier.unknown, "irreplaceable sorts before unknown")
    t.expect(Tier.exact <= .costly, "action ceiling admits exact and costly")
    t.expect(!(Tier.irreplaceable <= .costly), "action ceiling excludes irreplaceable")

    t.section("Recipe")
    let r = Recipe(kind: .ollamaPull, command: "ollama pull llama3:8b",
                   parameters: ["digest": "sha256:abc"],
                   cost: Cost(seconds: nil, bytesToRefetch: 4_700_000_000))
    t.equal(r.kind, .ollamaPull, "recipe kind round-trips")
    t.equal(r.parameters["digest"], "sha256:abc", "recipe parameters retained")

    t.section("Artefact")
    let a = Artefact(id: "ollama.models", path: URL(fileURLWithPath: "/tmp/x"),
                     logicalBytes: 100, physicalBytes: 90, tier: .exact, recipe: r)
    t.equal(a.tier, .exact, "artefact carries tier")
    t.expect(a.recipe != nil, "artefact carries recipe")

    runScannerTests(t)
    runCatalogueTests(t)
    runClassifierTests(t)
    runValidatorTests(t)
    await runAsyncValidatorTests(t)

    return t.report()
}

let status = await runAll()
exit(status)
```

Rename `Sources/ReclaimTests/main.swift` to `Sources/ReclaimTests/Main.swift` and mark the entry point, because top-level `await` requires it:

```swift
@main
struct TestRunner {
    static func main() async {
        exit(await runAll())
    }
}
```

Keep `runAll()` in the same file but remove the trailing `let status = ...` lines when using `@main`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `cannot find 'applyValidation' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ReclaimCore/Validator.swift`:

```swift
import Foundation

public enum ValidationResult: Sendable, Equatable {
    case proven(Recipe)
    case unproven(reason: String)
}

public protocol RecipeValidator: Sendable {
    func validate(_ artefact: Artefact) async -> ValidationResult
}

/// The product guarantee, in one function: anything we cannot prove we can
/// restore becomes irreplaceable, and irreplaceable is never actioned.
public func applyValidation(_ artefact: Artefact, _ result: ValidationResult) -> Artefact {
    var out = artefact
    switch result {
    case .proven(let recipe):
        out.recipe = recipe
    case .unproven:
        out.recipe = nil
        out.tier = .irreplaceable
    }
    return out
}

public struct AlwaysProvenValidator: RecipeValidator {
    private let recipe: Recipe
    public init(recipe: Recipe) { self.recipe = recipe }
    public func validate(_ artefact: Artefact) async -> ValidationResult { .proven(recipe) }
}

public struct NeverProvenValidator: RecipeValidator {
    private let reason: String
    public init(reason: String) { self.reason = reason }
    public func validate(_ artefact: Artefact) async -> ValidationResult { .unproven(reason: reason) }
}

/// Proves a recipe by running a real command and requiring exit status 0.
public struct CommandValidator: RecipeValidator {
    private let executable: String
    private let arguments: [String]
    private let recipe: Recipe

    public init(executable: String, arguments: [String], recipe: Recipe) {
        self.executable = executable
        self.arguments = arguments
        self.recipe = recipe
    }

    public func validate(_ artefact: Artefact) async -> ValidationResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .unproven(reason: "\(executable) is not available")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unproven(reason: "\(executable) failed to launch: \(error)")
        }
        guard process.terminationStatus == 0 else {
            return .unproven(reason: "\(executable) exited \(process.terminationStatus)")
        }
        return .proven(recipe)
    }
}

public enum ValidationRegistry {
    /// Resolve a catalogue `validator` name. Returns nil for unrecognised names —
    /// there is deliberately no permissive default.
    public static func validator(named name: String, recipeKind: Recipe.Kind?) -> RecipeValidator? {
        switch name {
        case "none":
            return NeverProvenValidator(reason: "no restore recipe exists for this artefact")
        case "alwaysProven":
            guard let kind = recipeKind else { return nil }
            return AlwaysProvenValidator(recipe: Recipe(kind: kind, command: command(for: kind)))
        case "ollama":
            return CommandValidator(executable: "/usr/local/bin/ollama", arguments: ["list"],
                                    recipe: Recipe(kind: .ollamaPull, command: "ollama pull <model>"))
        case "huggingface":
            return CommandValidator(executable: "/usr/bin/curl",
                                    arguments: ["-sf", "-o", "/dev/null", "https://huggingface.co"],
                                    recipe: Recipe(kind: .huggingFaceDownload,
                                                   command: "huggingface-cli download <repo> --revision <rev>"))
        default:
            return nil
        }
    }

    private static func command(for kind: Recipe.Kind) -> String {
        switch kind {
        case .ollamaPull: "ollama pull <model>"
        case .huggingFaceDownload: "huggingface-cli download <repo>"
        case .npmCleanInstall: "npm ci"
        case .homebrewFetch: "brew fetch <formula>"
        case .pipDownload: "pip download <package>"
        case .rebuild: "rebuild the project"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS, including all validator assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: validators and the downgrade-on-failure guarantee"
```

---

### Task 6: Append-only manifest store

**Files:**
- Create: `Sources/ReclaimCore/Manifest.swift`
- Create: `Sources/ReclaimTests/ManifestTests.swift`
- Modify: `Sources/ReclaimTests/Main.swift`

**Interfaces:**
- Consumes: `Tier`, `Recipe`.
- Produces: `ManifestEntry` (`artefactID`, `path`, `tier`, `bytesFreed`, `recipe`, `timestamp`, `snapshotName`), `ManifestStore(url:)`, `ManifestStore.append(_:) throws`, `ManifestStore.all() throws -> [ManifestEntry]`.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/ManifestTests.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runManifestTests(_ t: Harness) {
    t.section("Manifest")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("reclaim-manifest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ManifestStore(url: dir.appendingPathComponent("manifest.jsonl"))

    t.equal((try? store.all().count) ?? -1, 0, "empty store reads as empty, not an error")

    let e1 = ManifestEntry(artefactID: "ollama.models", path: "/fixture/models",
                           tier: .exact, bytesFreed: 14_000_000_000,
                           recipe: Recipe(kind: .ollamaPull, command: "ollama pull llama3:8b"),
                           timestamp: Date(timeIntervalSince1970: 1000), snapshotName: nil)
    let e2 = ManifestEntry(artefactID: "npm.cache", path: "/fixture/npm",
                           tier: .exact, bytesFreed: 4_200_000_000,
                           recipe: Recipe(kind: .npmCleanInstall, command: "npm ci"),
                           timestamp: Date(timeIntervalSince1970: 2000), snapshotName: nil)

    try? store.append(e1)
    try? store.append(e2)

    guard let all = try? store.all() else {
        t.expect(false, "store reads back")
        return
    }
    t.equal(all.count, 2, "both entries persisted")
    t.equal(all[0].artefactID, "ollama.models", "append order preserved")
    t.equal(all[1].bytesFreed, 4_200_000_000, "bytes freed round-trip")
    t.equal(all[0].recipe.command, "ollama pull llama3:8b", "restore command round-trips verbatim")

    // A second store over the same file must see prior entries — append-only, not truncating.
    let reopened = ManifestStore(url: dir.appendingPathComponent("manifest.jsonl"))
    t.equal((try? reopened.all().count) ?? -1, 2, "reopening does not truncate")

    // A corrupt line must not destroy the whole log.
    let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent("manifest.jsonl"))
    try? handle?.seekToEnd()
    try? handle?.write(contentsOf: Data("{not json\n".utf8))
    try? handle?.close()
    t.equal((try? reopened.all().count) ?? -1, 2, "corrupt line is skipped, valid entries survive")
}
```

Add `runManifestTests(t)` to `runAll()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `cannot find 'ManifestStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ReclaimCore/Manifest.swift`:

```swift
import Foundation

public struct ManifestEntry: Codable, Sendable, Equatable {
    public var artefactID: String
    public var path: String
    public var tier: Tier
    public var bytesFreed: Int64
    public var recipe: Recipe
    public var timestamp: Date
    public var snapshotName: String?

    public init(artefactID: String, path: String, tier: Tier, bytesFreed: Int64,
                recipe: Recipe, timestamp: Date = Date(), snapshotName: String? = nil) {
        self.artefactID = artefactID
        self.path = path
        self.tier = tier
        self.bytesFreed = bytesFreed
        self.recipe = recipe
        self.timestamp = timestamp
        self.snapshotName = snapshotName
    }
}

/// Append-only JSON Lines log of every reclaim, and the sole source of truth
/// for restores. One corrupt line must never cost the user the rest of the log.
public struct ManifestStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(_ entry: ManifestEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    public func all() throws -> [ManifestEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(ManifestEntry.self, from: Data(line.utf8))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS, including all seven manifest assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: append-only manifest store resilient to corrupt lines"
```

---

### Task 7: Executor with dry-run default

**Files:**
- Create: `Sources/ReclaimCore/Executor.swift`
- Create: `Sources/ReclaimTests/ExecutorTests.swift`
- Modify: `Sources/ReclaimTests/Main.swift`

**Interfaces:**
- Consumes: `Artefact`, `Tier`, `ManifestStore`, `ManifestEntry`, `Recipe`.
- Produces: `ExecutionMode` (`.dryRun` / `.reclaim`), `ExecutionOutcome` (`.wouldReclaim(Int64)` / `.reclaimed(Int64)` / `.skipped(reason: String)`), `Executor(manifest:mode:)`, `Executor.execute(_ artefacts: [Artefact]) throws -> [(Artefact, ExecutionOutcome)]`.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/ExecutorTests.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runExecutorTests(_ t: Harness) {
    t.section("Executor")

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("reclaim-exec-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    func makeVictim(_ name: String) -> URL {
        let p = dir.appendingPathComponent(name)
        try? fm.createDirectory(at: p, withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: 1024).write(to: p.appendingPathComponent("f.bin"))
        return p
    }

    let recipe = Recipe(kind: .npmCleanInstall, command: "npm ci")

    // Dry run must not delete anything.
    let v1 = makeVictim("dryrun")
    let dryStore = ManifestStore(url: dir.appendingPathComponent("dry.jsonl"))
    let dry = Executor(manifest: dryStore, mode: .dryRun)
    let a1 = Artefact(id: "npm.cache", path: v1, logicalBytes: 1024, physicalBytes: 4096,
                      tier: .exact, recipe: recipe)
    let dryResults = (try? dry.execute([a1])) ?? []
    t.equal(dryResults.count, 1, "dry run reports one result")
    if case .wouldReclaim(let bytes) = dryResults.first?.1 {
        t.equal(bytes, 4096, "dry run reports physical bytes")
    } else {
        t.expect(false, "dry run yields wouldReclaim")
    }
    t.expect(fm.fileExists(atPath: v1.path), "dry run leaves the directory intact")
    t.equal((try? dryStore.all().count) ?? -1, 0, "dry run writes no manifest entry")

    // Reclaim must delete and record.
    let v2 = makeVictim("live")
    let liveStore = ManifestStore(url: dir.appendingPathComponent("live.jsonl"))
    let live = Executor(manifest: liveStore, mode: .reclaim)
    let a2 = Artefact(id: "npm.cache", path: v2, logicalBytes: 1024, physicalBytes: 4096,
                      tier: .exact, recipe: recipe)
    let liveResults = (try? live.execute([a2])) ?? []
    if case .reclaimed(let bytes) = liveResults.first?.1 {
        t.equal(bytes, 4096, "reclaim reports physical bytes")
    } else {
        t.expect(false, "reclaim yields reclaimed")
    }
    t.expect(!fm.fileExists(atPath: v2.path), "reclaim removes the directory")
    t.equal((try? liveStore.all().count) ?? -1, 1, "reclaim records one manifest entry")
    t.equal((try? liveStore.all())?.first?.recipe.command, "npm ci", "manifest stores the restore command")

    // The guarantee: no recipe means no deletion, whatever the tier claims.
    let v3 = makeVictim("norecipe")
    let g1 = Artefact(id: "npm.cache", path: v3, logicalBytes: 1024, physicalBytes: 4096,
                      tier: .exact, recipe: nil)
    let r3 = (try? live.execute([g1])) ?? []
    if case .skipped(let reason) = r3.first?.1 {
        t.expect(reason.contains("recipe"), "skip reason names the missing recipe")
    } else {
        t.expect(false, "artefact without a recipe is skipped")
    }
    t.expect(fm.fileExists(atPath: v3.path), "artefact without a recipe survives")

    // Irreplaceable is never actioned, even holding a recipe.
    let v4 = makeVictim("irreplaceable")
    let g2 = Artefact(id: "docker.volumes", path: v4, logicalBytes: 1024, physicalBytes: 4096,
                      tier: .irreplaceable, recipe: recipe)
    let r4 = (try? live.execute([g2])) ?? []
    if case .skipped = r4.first?.1 {
        t.expect(true, "irreplaceable artefact is skipped")
    } else {
        t.expect(false, "irreplaceable artefact is skipped")
    }
    t.expect(fm.fileExists(atPath: v4.path), "irreplaceable artefact survives")

    // Unknown is never actioned.
    let v5 = makeVictim("unknown")
    let g3 = Artefact(id: "unknown", path: v5, logicalBytes: 1024, physicalBytes: 4096,
                      tier: .unknown, recipe: nil)
    _ = try? live.execute([g3])
    t.expect(fm.fileExists(atPath: v5.path), "unknown artefact survives")
}
```

Add `runExecutorTests(t)` to `runAll()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `cannot find 'Executor' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ReclaimCore/Executor.swift`:

```swift
import Foundation

public enum ExecutionMode: Sendable {
    case dryRun
    case reclaim
}

public enum ExecutionOutcome: Sendable, Equatable {
    case wouldReclaim(Int64)
    case reclaimed(Int64)
    case skipped(reason: String)
}

public struct Executor: Sendable {
    private let manifest: ManifestStore
    private let mode: ExecutionMode

    public init(manifest: ManifestStore, mode: ExecutionMode = .dryRun) {
        self.manifest = manifest
        self.mode = mode
    }

    public func execute(_ artefacts: [Artefact]) throws -> [(Artefact, ExecutionOutcome)] {
        var results: [(Artefact, ExecutionOutcome)] = []
        for artefact in artefacts {
            results.append((artefact, try execute(artefact)))
        }
        return results
    }

    private func execute(_ artefact: Artefact) throws -> ExecutionOutcome {
        guard artefact.tier <= Tier.automaticCeiling else {
            return .skipped(reason: "tier \(artefact.tier.rawValue) is never actioned automatically")
        }
        guard let recipe = artefact.recipe else {
            return .skipped(reason: "no validated restore recipe")
        }
        guard mode == .reclaim else {
            return .wouldReclaim(artefact.physicalBytes)
        }

        try FileManager.default.removeItem(at: artefact.path)

        try manifest.append(ManifestEntry(artefactID: artefact.id,
                                          path: artefact.path.path,
                                          tier: artefact.tier,
                                          bytesFreed: artefact.physicalBytes,
                                          recipe: recipe))
        return .reclaimed(artefact.physicalBytes)
    }
}
```

Make `ExecutionMode` equatable by adding `: Equatable` — required by `mode == .reclaim`:

```swift
public enum ExecutionMode: Sendable, Equatable {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS, including all thirteen executor assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: executor with dry-run default and no-recipe-no-deletion rule"
```

---

### Task 8: Restore engine and round-trip proof

**Files:**
- Create: `Sources/ReclaimCore/RestoreEngine.swift`
- Create: `Sources/ReclaimTests/RestoreTests.swift`
- Modify: `Sources/ReclaimTests/Main.swift`

**Interfaces:**
- Consumes: `ManifestStore`, `ManifestEntry`, `Recipe`.
- Produces: `RestorePlan` (`entry: ManifestEntry`, `command: String`), `RestoreEngine(manifest:)`, `RestoreEngine.plan(for path: String) throws -> RestorePlan?`, `RestoreEngine.planAll() throws -> [RestorePlan]`.

**Note:** v1 *emits* the restore command rather than executing it. Running `ollama pull` or `npm ci` on the user's behalf is a separate consent decision, and printing the exact command is already the thing no competitor offers. Executing recipes is deferred deliberately, not forgotten.

- [ ] **Step 1: Write the failing test**

Create `Sources/ReclaimTests/RestoreTests.swift`:

```swift
import Foundation
import ReclaimCore

@MainActor func runRestoreTests(_ t: Harness) {
    t.section("Restore engine")

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("reclaim-restore-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = ManifestStore(url: dir.appendingPathComponent("m.jsonl"))
    try? store.append(ManifestEntry(artefactID: "ollama.models", path: "/fixture/models",
                                    tier: .exact,
                                    bytesFreed: 14_000_000_000,
                                    recipe: Recipe(kind: .ollamaPull,
                                                   command: "ollama pull llama3:8b",
                                                   parameters: ["digest": "sha256:abc"])))

    let engine = RestoreEngine(manifest: store)

    guard let plan = try? engine.plan(for: "/fixture/models") else {
        t.expect(false, "plan found for a reclaimed path")
        return
    }
    t.expect(plan != nil, "plan exists for a reclaimed path")
    t.equal(plan?.command, "ollama pull llama3:8b", "plan emits the exact recorded command")

    let none = try? engine.plan(for: "/never/reclaimed")
    t.expect((none ?? nil) == nil, "no plan for a path never reclaimed")

    t.equal((try? engine.planAll().count) ?? -1, 1, "planAll returns every recorded reclaim")

    t.section("Round trip")
    // Full cycle: create → classify → validate → reclaim → restore command recovered.
    let victim = dir.appendingPathComponent("cache")
    try? fm.createDirectory(at: victim, withIntermediateDirectories: true)
    try? Data(repeating: 0x43, count: 2048).write(to: victim.appendingPathComponent("blob"))

    let measured = (try? Scanner.measure(victim)) ?? .zero
    t.equal(measured.fileCount, 1, "round trip: fixture measured")

    let catJSON = """
    {"version":1,"entries":[{"id":"npm.cache","displayName":"npm cache",
      "path":"\(victim.path)","tier":"exact","recipeKind":"npmCleanInstall",
      "validator":"alwaysProven"}]}
    """.data(using: .utf8)!
    let cat = try! Catalogue.load(from: catJSON)
    let classified = Classifier(catalogue: cat).classify(path: victim, measurement: measured)
    t.equal(classified.tier, .exact, "round trip: classified as exact")

    let validated = applyValidation(classified,
        .proven(Recipe(kind: .npmCleanInstall, command: "npm ci")))
    t.expect(validated.recipe != nil, "round trip: recipe attached")

    let rtStore = ManifestStore(url: dir.appendingPathComponent("rt.jsonl"))
    let outcomes = (try? Executor(manifest: rtStore, mode: .reclaim).execute([validated])) ?? []
    if case .reclaimed = outcomes.first?.1 {
        t.expect(true, "round trip: reclaimed")
    } else {
        t.expect(false, "round trip: reclaimed")
    }
    t.expect(!fm.fileExists(atPath: victim.path), "round trip: bytes actually freed")

    let recovered = try? RestoreEngine(manifest: rtStore).plan(for: victim.path)
    t.equal((recovered ?? nil)?.command, "npm ci", "round trip: restore command recovered from manifest")
}
```

Add `runRestoreTests(t)` to `runAll()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run -q ReclaimTests`
Expected: FAIL — `cannot find 'RestoreEngine' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ReclaimCore/RestoreEngine.swift`:

```swift
import Foundation

public struct RestorePlan: Sendable, Equatable {
    public var entry: ManifestEntry
    /// The exact command that restores this artefact.
    public var command: String
}

public struct RestoreEngine: Sendable {
    private let manifest: ManifestStore

    public init(manifest: ManifestStore) { self.manifest = manifest }

    public func plan(for path: String) throws -> RestorePlan? {
        try manifest.all()
            .last { $0.path == path }
            .map { RestorePlan(entry: $0, command: $0.recipe.command) }
    }

    public func planAll() throws -> [RestorePlan] {
        try manifest.all().map { RestorePlan(entry: $0, command: $0.recipe.command) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run -q ReclaimTests`
Expected: PASS, including the round-trip assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: restore engine recovering exact commands from the manifest"
```

---

### Task 9: CLI

**Files:**
- Modify: `Sources/reclaim/main.swift` (replace the placeholder entirely)
- Create: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: `reclaim scan`, `reclaim plan`, `reclaim reclaim --confirm`, `reclaim restore`.

**Safety requirement:** `reclaim reclaim` without `--confirm` must behave as a dry run. Destructive behaviour is opt-in on every single invocation.

- [ ] **Step 1: Write the failing test**

There is no unit test for `main.swift`; it is verified by running it. Write the acceptance check as a shell script, `scripts/acceptance.sh`:

```bash
#!/bin/bash
# Acceptance: the CLI must never delete without --confirm.
set -euo pipefail

FIXTURE=$(mktemp -d)/npm-cache
mkdir -p "$FIXTURE"
head -c 4096 /dev/zero > "$FIXTURE/blob"

echo "== scan =="
swift run -q reclaim scan "$FIXTURE"

echo "== reclaim without --confirm (must not delete) =="
swift run -q reclaim reclaim "$FIXTURE"
test -e "$FIXTURE/blob" || { echo "FAIL: deleted without --confirm"; exit 1; }
echo "ok: fixture survived"

rm -rf "$(dirname "$FIXTURE")"
echo "ACCEPTANCE PASS"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x scripts/acceptance.sh && ./scripts/acceptance.sh`
Expected: FAIL — the CLI prints `reclaim: no commands yet` and the scan produces no output.

- [ ] **Step 3: Write minimal implementation**

Replace `Sources/reclaim/main.swift`:

```swift
import Foundation
import ReclaimCore

func humanBytes(_ b: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(b)
    var i = 0
    while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
    return String(format: "%.1f %@", value, units[i])
}

func manifestURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("DiskReclaim/manifest.jsonl")
}

func loadCatalogue(overridePath: String?) -> Catalogue {
    if let overridePath, let data = FileManager.default.contents(atPath: overridePath),
       let c = try? Catalogue.load(from: data) {
        return c
    }
    if let c = try? Catalogue.bundled() { return c }
    FileHandle.standardError.write(Data("reclaim: catalogue unavailable\n".utf8))
    exit(2)
}

/// Measure and classify every catalogued path that exists, plus any explicit paths.
func survey(_ catalogue: Catalogue, extraPaths: [String]) -> [Artefact] {
    let classifier = Classifier(catalogue: catalogue)
    var targets = catalogue.entries.map(\.expandedPath)
    targets.append(contentsOf: extraPaths)

    var out: [Artefact] = []
    for path in targets {
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let url = URL(fileURLWithPath: path)
        guard let m = try? Scanner.measure(url) else { continue }
        out.append(classifier.classify(path: url, measurement: m))
    }
    return out.sorted { $0.physicalBytes > $1.physicalBytes }
}

func validate(_ artefacts: [Artefact], _ catalogue: Catalogue) async -> [Artefact] {
    var out: [Artefact] = []
    for a in artefacts {
        guard let entry = catalogue.entry(id: a.id) else { out.append(a); continue }
        guard let validator = ValidationRegistry.validator(named: entry.validator,
                                                           recipeKind: entry.recipeKind) else {
            out.append(applyValidation(a, .unproven(reason: "unknown validator '\(entry.validator)'")))
            continue
        }
        out.append(applyValidation(a, await validator.validate(a)))
    }
    return out
}

func printTable(_ artefacts: [Artefact]) {
    guard !artefacts.isEmpty else { print("nothing found"); return }
    for a in artefacts {
        let mark = a.tier <= Tier.automaticCeiling && a.recipe != nil ? "✓" : "·"
        print(String(format: "%@ %10@  %-14@ %@", mark, humanBytes(a.physicalBytes),
                     a.tier.rawValue, a.path.path))
        if let r = a.recipe {
            print("             restore: \(r.command)")
        }
    }
    let total = artefacts.filter { $0.tier <= Tier.automaticCeiling && $0.recipe != nil }
        .reduce(Int64(0)) { $0 + $1.physicalBytes }
    print("\nreclaimable: \(humanBytes(total))")
}

@main
struct CLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let confirm = args.contains("--confirm")
        args.removeAll { $0 == "--confirm" }
        let command = args.first ?? "scan"
        let paths = Array(args.dropFirst())

        let catalogue = loadCatalogue(overridePath: ProcessInfo.processInfo.environment["RECLAIM_CATALOGUE"])
        let store = ManifestStore(url: manifestURL())

        switch command {
        case "scan":
            printTable(survey(catalogue, extraPaths: paths))

        case "plan":
            printTable(await validate(survey(catalogue, extraPaths: paths), catalogue))

        case "reclaim":
            let artefacts = await validate(survey(catalogue, extraPaths: paths), catalogue)
            let mode: ExecutionMode = confirm ? .reclaim : .dryRun
            if !confirm { print("DRY RUN — pass --confirm to actually reclaim\n") }
            guard let results = try? Executor(manifest: store, mode: mode).execute(artefacts) else {
                FileHandle.standardError.write(Data("reclaim: execution failed\n".utf8))
                exit(1)
            }
            var freed: Int64 = 0
            for (artefact, outcome) in results {
                switch outcome {
                case .wouldReclaim(let b):
                    freed += b
                    print("would free \(humanBytes(b))  \(artefact.path.path)")
                case .reclaimed(let b):
                    freed += b
                    print("freed      \(humanBytes(b))  \(artefact.path.path)")
                case .skipped(let reason):
                    print("skipped                \(artefact.path.path) — \(reason)")
                }
            }
            print("\ntotal: \(humanBytes(freed))")

        case "restore":
            guard let plans = try? RestoreEngine(manifest: store).planAll() else {
                print("no manifest yet"); return
            }
            if plans.isEmpty { print("nothing has been reclaimed") }
            for p in plans {
                print("\(p.entry.path)\n  \(p.command)  [\(humanBytes(p.entry.bytesFreed))]")
            }

        default:
            print("""
            usage: reclaim <command> [paths...]

              scan        measure catalogued artefacts
              plan        measure and validate restore recipes
              reclaim     free space (dry run unless --confirm)
              restore     show restore commands for what was freed
            """)
        }
    }
}
```

Create `README.md`:

```markdown
# Disk Reclaim

Reclaims developer and AI-model disk artefacts on macOS. Nothing is deleted
unless its restore recipe has just been validated against reality.

## Usage

    swift run reclaim scan       # measure
    swift run reclaim plan       # measure and validate restore recipes
    swift run reclaim reclaim    # dry run
    swift run reclaim reclaim --confirm
    swift run reclaim restore    # show how to bring anything back

## Tiers

| Tier | Meaning | Actioned |
|---|---|---|
| exact | restores byte-identical from a recipe | automatically |
| costly | regenerates, at a time cost | automatically, cost shown |
| irreplaceable | no recipe exists | never |
| unknown | not in the catalogue | never |

## Known limitations

- Byte accounting deduplicates **hardlinks** by `(device, inode)`. True APFS
  *clone* accounting, where distinct inodes share blocks, is not implemented.
- `restore` prints the exact recovery command; it does not run it.
- Requires Full Disk Access to read `~/Library`.

## Tests

    swift run -q ReclaimTests
    ./scripts/acceptance.sh
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run -q ReclaimTests && ./scripts/acceptance.sh`
Expected: unit suite PASS, then `ACCEPTANCE PASS`.

Then run it for real, read-only: `swift run -q reclaim plan`
Expected: a table of the catalogued artefacts present on this machine, with restore commands and a reclaimable total.

- [ ] **Step 5: Commit**

```bash
git add Sources README.md scripts
git commit -m "feat: reclaim CLI with dry-run-by-default reclaim"
```

---

## Self-Review

**Spec coverage.**

| Spec requirement | Task |
|---|---|
| Tier model T0–T3 | 1 |
| Unknown is never touched | 4, 7 |
| Scanner, inode-correct | 2 |
| Catalogue as data, updatable | 3 |
| v1 catalogue entries | 3 |
| Classifier | 4 |
| Validate before destroy; downgrade on failure | 5, 7 |
| Manifest, append-only, outside reclaimable paths | 6 |
| Executor, dry-run default, atomic per artefact | 7 |
| Restore engine | 8 |
| Round-trip test | 8 |
| CLI deliverable | 9 |

**Deliberately deferred, with reasons:**
- **APFS snapshots for tier T2.** T2 is never actioned in v1, so the snapshot path has no caller. Adding it before anything can reach it would be untested code guarding nothing.
- **Docker and Ollama CLI probes.** The catalogue currently reaches Docker and Ollama through filesystem paths. Probes matter once we split Docker's build cache (reclaimable) from its volumes (not) at sub-artefact granularity, which needs the probe to enumerate them.
- **Running restore commands.** v1 prints them. Executing on the user's behalf is a distinct consent decision.
- **Low Power Mode and running-build detection.** These guard automatic background operation, which v1 does not do — it only acts on an explicit command.
- **SwiftUI shell.** Blocked on Xcode, which is blocked on disk space.

Each is recorded here rather than dropped, and none is required for the guarantee v1 exists to prove.

**Type consistency.** `Tier`, `Cost`, `Recipe`, `Recipe.Kind`, `Artefact`, `Scanner.Measurement`, `CatalogueEntry`, `Catalogue`, `Classifier`, `ValidationResult`, `RecipeValidator`, `applyValidation`, `ValidationRegistry`, `ManifestEntry`, `ManifestStore`, `ExecutionMode`, `ExecutionOutcome`, `Executor`, `RestorePlan`, `RestoreEngine` — each is defined once and used with consistent signatures throughout. `Tier.automaticCeiling` is the single gate consulted by both `Executor` and the CLI.
