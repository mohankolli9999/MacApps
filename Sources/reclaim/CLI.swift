import Foundation
import ReclaimCore

func humanBytes(_ b: Int64) -> String { ByteFormat.decimal.string(b) }

func loadCatalogue(overridePath: String?) -> Catalogue {
    if let overridePath, let data = FileManager.default.contents(atPath: overridePath),
       let c = try? Catalogue.load(from: data) {
        return c
    }
    if let c = try? Catalogue.bundled() { return c }
    FileHandle.standardError.write(Data("reclaim: catalogue unavailable\n".utf8))
    exit(2)
}

/// Measure and classify the paths in scope: the whole catalogue, or only the
/// explicit paths if any were given.
func survey(_ catalogue: Catalogue, only paths: [String]) -> [Artefact] {
    let classifier = Classifier(catalogue: catalogue)
    let targets = Survey.targets(catalogue: catalogue, explicitPaths: paths)

    var out: [Artefact] = []
    for path in targets {
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let url = URL(fileURLWithPath: path)
        guard let m = try? DiskScanner.measure(url) else { continue }
        out.append(classifier.classify(path: url, measurement: m))
    }
    return out.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
}

func validate(_ artefacts: [Artefact], _ catalogue: Catalogue) async -> [Artefact] {
    var out: [Artefact] = []
    for a in artefacts {
        guard let entry = catalogue.entry(id: a.id) else { out.append(a); continue }
        guard let validator = ValidationRegistry.validator(for: entry) else {
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
        let actionable = a.tier <= Tier.automaticCeiling && a.recipe != nil
        let mark = actionable ? "*" : " "
        print("\(mark) \(humanBytes(a.reclaimableBytes).padded(to: 10))  \(a.tier.rawValue.padded(to: 14)) \(a.path.path)")
        if let r = a.recipe {
            print("               restore: \(r.command)")
        }
    }
    let total = artefacts.filter { $0.tier <= Tier.automaticCeiling && $0.recipe != nil }
        .reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    print("\nreclaimable: \(humanBytes(total))")
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
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
        let store = ManifestStore.standard

        switch command {
        case "scan":
            printTable(survey(catalogue, only: paths))

        case "plan":
            printTable(await validate(survey(catalogue, only: paths), catalogue))

        case "reclaim":
            let scope = Survey.targets(catalogue: catalogue, explicitPaths: paths)
            print("scope: \(paths.isEmpty ? "whole catalogue" : "\(scope.count) explicit path(s)")")
            for path in scope { print("  \(path)") }
            print("")
            let artefacts = await validate(survey(catalogue, only: paths), catalogue)
            let mode: ExecutionMode = confirm ? .reclaim : .dryRun
            if !confirm { print("DRY RUN - pass --confirm to actually reclaim\n") }
            guard let results = try? ReclaimExecutor(manifest: store, mode: mode).execute(artefacts) else {
                FileHandle.standardError.write(Data("reclaim: execution failed\n".utf8))
                exit(1)
            }
            var freed: Int64 = 0
            for (artefact, outcome) in results {
                switch outcome {
                case .wouldReclaim(let b):
                    freed += b
                    print("would free \(humanBytes(b).padded(to: 10))  \(artefact.path.path)")
                case .reclaimed(let b):
                    freed += b
                    print("freed      \(humanBytes(b).padded(to: 10))  \(artefact.path.path)")
                case .skipped(let reason):
                    print("skipped                \(artefact.path.path) - \(reason)")
                }
            }
            print("\ntotal: \(humanBytes(freed))")

        case "restore":
            guard let plans = try? RestoreEngine(manifest: store).history() else {
                print("no manifest yet"); return
            }
            if plans.isEmpty { print("nothing has been reclaimed") }
            for p in plans {
                let state = p.isRestored ? "  (restored)" : ""
                let proof = p.entry.recipe.isConcrete ? "" : "  [template - will not restore]"
                print("\(p.entry.path)\(state)\n  \(p.command)  [\(humanBytes(p.entry.bytesFreed))]\(proof)")
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
