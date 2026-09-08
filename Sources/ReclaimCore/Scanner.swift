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
        public var physicalBytes: Int64
        public var fileCount: Int

        public init(logicalBytes: Int64, physicalBytes: Int64, fileCount: Int) {
            self.logicalBytes = logicalBytes
            self.physicalBytes = physicalBytes
            self.fileCount = fileCount
        }

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

        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            throw ScanError.unreadable(url.path)
        }

        for case let child as URL in e {
            account(child.path)
        }
        return result
    }
}
