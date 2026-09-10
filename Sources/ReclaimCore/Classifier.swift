import Foundation

public struct Classifier: Sendable {
    private let catalogue: Catalogue

    public init(catalogue: Catalogue) {
        self.catalogue = catalogue
    }

    /// Map a measured path onto a catalogue entry. Anything unrecognised is
    /// `.unknown`, which is never actionable.
    public func classify(path: URL, measurement: DiskScanner.Measurement) -> Artefact {
        let target = path.standardizedFileURL.path

        let match = catalogue.entries.first { entry in
            let base = entry.expandedPath
            return target == base || target.hasPrefix(base + "/")
        }

        guard let entry = match else {
            return Artefact(id: "unknown",
                            path: path,
                            logicalBytes: measurement.logicalBytes,
                            reclaimableBytes: measurement.reclaimableBytes,
                            tier: .unknown)
        }

        return Artefact(id: entry.id,
                        path: path,
                        logicalBytes: measurement.logicalBytes,
                        reclaimableBytes: measurement.reclaimableBytes,
                        tier: entry.tier)
    }
}
