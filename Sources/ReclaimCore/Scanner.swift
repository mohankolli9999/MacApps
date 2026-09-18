import Foundation

public enum ScanError: Error, Equatable {
    case notFound(String)
    case unreadable(String)
}

/// Named `DiskScanner` rather than `Scanner` because Foundation exports a
/// `Scanner` class, and the collision makes every call site ambiguous.
public enum DiskScanner {
    public struct Measurement: Sendable, Equatable {
        public var logicalBytes: Int64
        /// What deleting the folder would return to the volume, and the only
        /// size this app quotes. Deliberately not "what it occupies": on APFS a
        /// file cloned from outside occupies blocks it cannot give back, and a
        /// tool that answers a folder's size two ways cannot be trusted about
        /// either.
        ///
        /// A floor rather than an exact answer. Summing each file's own share
        /// misses blocks whose entire clone family lives inside this folder —
        /// nobody owns them, yet deleting the folder takes them all. Crediting
        /// those needs family bookkeeping across the whole selection, which is
        /// `SelectionSpace`'s job. Erring low is the survivable direction: the
        /// user gets back at least what was promised.
        public var reclaimableBytes: Int64
        public var fileCount: Int

        public init(logicalBytes: Int64,
                    reclaimableBytes: Int64,
                    fileCount: Int) {
            self.logicalBytes = logicalBytes
            self.reclaimableBytes = reclaimableBytes
            self.fileCount = fileCount
        }

        public static let zero = Measurement(logicalBytes: 0, reclaimableBytes: 0, fileCount: 0)
    }

    private struct INode: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// Recursively measure a directory, counting each inode exactly once.
    ///
    /// `onProgress` is throttled to `progressInterval`, not called per file. A
    /// cache like ~/.npm/_cacache holds hundreds of thousands of files, and
    /// forwarding every one to the main actor would cost far more than the walk.
    /// Interpolating between sparse samples is the renderer's job.
    public static func measure(
        _ url: URL,
        progressInterval: TimeInterval = 0.06,
        onProgress: (Measurement) -> Void = { _ in },
        // Last so that a trailing closure binds to onProgress: Swift's forward
        // scan would otherwise match this one and silently discard progress.
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Measurement {
        guard let probe = FileSpace.inspect(url.path) else {
            throw ScanError.notFound(url.path)
        }

        var seen = Set<INode>()
        var result = Measurement.zero
        var lastReport = Date.distantPast

        func reportIfDue() {
            let now = Date()
            guard now.timeIntervalSince(lastReport) >= progressInterval else { return }
            lastReport = now
            onProgress(result)
        }

        func account(_ entry: FileSpace.Entry) {
            guard entry.kind == .file, !entry.isCloudPlaceholder else { return }
            guard seen.insert(INode(device: entry.device, inode: entry.inode)).inserted else { return }
            result.fileCount += 1
            result.logicalBytes += entry.logicalBytes
            result.reclaimableBytes += entry.reclaimableBytes
        }

        if probe.kind == .file {
            account(probe)
            return result
        }

        func walk(_ directory: String) {
            guard let entries = try? FileSpace.contents(of: directory) else { return }
            for listing in entries {
                if isCancelled() { return }
                if listing.entry.kind == .directory {
                    walk(directory + "/" + listing.name)
                } else {
                    account(listing.entry)
                }
                reportIfDue()
            }
        }

        guard (try? FileSpace.contents(of: url.path)) != nil else {
            throw ScanError.unreadable(url.path)
        }
        walk(url.path)
        return result
    }
}
