import Foundation

/// What the disk holds that walking folders will never find.
///
/// A folder walk can only report bytes that have a path. An APFS container also
/// carries volumes Finder hides, snapshots holding blocks for files that are
/// already deleted, and its own metadata outside every volume. Together those
/// are why "used" in System Settings exceeds anything a disk map adds up to, and
/// leaving them unnamed is what makes users think a disk tool is broken.
public enum VolumeLedger {
    public enum LedgerError: Error, Equatable {
        case malformed
        case unavailable
    }

    public struct Volume: Sendable, Equatable, Identifiable {
        public let device: String
        public let name: String
        public let roles: [String]
        /// What the volume reports occupying. Volumes in one container share
        /// free space but not used blocks, so these sum without double counting.
        public let usedBytes: Int64
        public var id: String { device }

        /// macOS presents System and Data as the single disk the user browses
        /// and hides the rest of the container behind it. Those hidden volumes
        /// hold real bytes — on a normal Mac, tens of gigabytes of them.
        public var isHidden: Bool { !roles.allSatisfy(Self.browsableRoles.contains) }

        private static let browsableRoles: Set<String> = ["System", "Data"]
    }

    public struct Container: Sendable, Equatable, Identifiable {
        public let device: String
        public let capacityBytes: Int64
        public let freeBytes: Int64
        public let volumes: [Volume]
        public var id: String { device }

        public var usedByVolumesBytes: Int64 { volumes.reduce(0) { $0 + $1.usedBytes } }

        /// Capacity the container has neither given to a volume nor left free:
        /// checkpoints, space-manager bitmaps, superblocks. None of it comes
        /// back by deleting files, which is the point of naming it — unnamed it
        /// reads as bytes the scan lost.
        public var unaccountedBytes: Int64 { capacityBytes - freeBytes - usedByVolumesBytes }
    }

    public struct Snapshot: Sendable, Equatable, Identifiable {
        public let uuid: String
        public let name: String
        public let xid: UInt64
        /// macOS drops a purgeable snapshot itself when the disk gets tight, so
        /// its blocks are already counted as available.
        public let isPurgeable: Bool
        public var id: String { uuid }
    }

    /// Everything off the folder map, read together so the numbers in it agree
    /// with each other.
    public struct Report: Sendable {
        public let containers: [Container]
        public let snapshots: [String: [Snapshot]]
        /// Bytes macOS would hand back on its own before it ran out: caches it
        /// can refetch, snapshots it can drop, files already copied to iCloud.
        public let purgeableBytes: Int64?

        public var hiddenVolumes: [Volume] { containers.flatMap(\.volumes).filter(\.isHidden) }
        public var hiddenBytes: Int64 { hiddenVolumes.reduce(0) { $0 + $1.usedBytes } }
        public var unaccountedBytes: Int64 { containers.reduce(0) { $0 + $1.unaccountedBytes } }
        public var allSnapshots: [Snapshot] { snapshots.values.flatMap { $0 } }
    }

    // MARK: - Reading the machine

    /// - Parameter boot: the volume to ask about purgeable space. Only the boot
    ///   volume answers; the rest report nothing rather than a wrong number.
    public static func read(boot: URL = URL(fileURLWithPath: "/")) throws -> Report {
        let containers = try containers(fromPlist: run(["apfs", "list", "-plist"]))
        var found: [String: [Snapshot]] = [:]
        for volume in containers.flatMap(\.volumes) {
            // A volume that is not mounted cannot be asked, and that is normal
            // rather than a failure worth abandoning the whole report over.
            guard let list = try? snapshots(of: volume.device), !list.isEmpty else { continue }
            found[volume.device] = list
        }
        return Report(containers: containers,
                      snapshots: found,
                      purgeableBytes: purgeableBytes(at: boot))
    }

    public static func snapshots(of device: String) throws -> [Snapshot] {
        guard isDeviceIdentifier(device) else { throw LedgerError.malformed }
        return try snapshots(fromPlist: run(["apfs", "listSnapshots", "-plist", device]))
    }

    /// diskutil reads options and device identifiers from the same argument
    /// position, so an identifier beginning with a dash becomes a flag. These
    /// come from diskutil's own output, but that is still another program's
    /// output, and this is where it turns into an argument.
    public static func isDeviceIdentifier(_ value: String) -> Bool {
        var rest = Substring(value)
        guard rest.hasPrefix("disk") else { return false }
        rest = rest.dropFirst(4)
        while true {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty else { return false }
            rest = rest.dropFirst(digits.count)
            if rest.isEmpty { return true }
            guard rest.hasPrefix("s") else { return false }
            rest = rest.dropFirst()
        }
    }

    /// Whether a mount point is one of the volumes macOS keeps for itself and
    /// hides from Finder.
    ///
    /// They sit directly under `/System/Volumes`. Deeper mounts share the prefix
    /// but are not volumes of their own — an installer's second mount of the
    /// boot disk, the autofs home map — and treating them as such shows the same
    /// bytes twice under a second name. The Data volume is excluded for that
    /// reason too: macOS firmlinks it into `/`, so it is already counted there.
    public static func isSystemVolumeMount(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return parts.count == 4
            && parts[1] == "System" && parts[2] == "Volumes"
            && parts[3] != "Data"
    }

    /// What a volume holds and what is left, without walking it.
    public struct Space: Sendable, Equatable {
        public let capacity: Int64
        public let free: Int64
        public var used: Int64 { capacity - free }
    }

    /// Answers in a syscall what a scan takes a minute to reach, so the window
    /// has something true on it from the first frame. "Important usage" rather
    /// than raw availability because it is the figure Finder shows, and quoting
    /// a different free-space number than the rest of the Mac reads as a bug.
    public static func space(at url: URL) -> Space? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let capacity = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Space(capacity: Int64(capacity), free: min(free, Int64(capacity)))
    }

    public static func purgeableBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        // Every volume but the boot one reports zero here, meaning "not asked
        // of me" rather than "nothing purgeable". Subtracting from that claims
        // a deficit the size of the disk.
        guard important >= Int64(available) else { return nil }
        return important - Int64(available)
    }

    private static func run(_ arguments: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { throw LedgerError.unavailable }
        // Draining before waiting: a full pipe buffer stops the child exiting,
        // and waiting first would then never return.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw LedgerError.unavailable }
        return data
    }

    // MARK: - Parsing

    public static func containers(fromPlist data: Data) throws -> [Container] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entries = (root as? [String: Any])?["Containers"] as? [[String: Any]]
        else { throw LedgerError.malformed }

        return try entries.map { entry in
            guard let device = entry["ContainerReference"] as? String,
                  let ceiling = entry["CapacityCeiling"] as? NSNumber,
                  let free = entry["CapacityFree"] as? NSNumber,
                  let volumes = entry["Volumes"] as? [[String: Any]]
            else { throw LedgerError.malformed }

            return Container(device: device,
                             capacityBytes: ceiling.int64Value,
                             freeBytes: free.int64Value,
                             volumes: try volumes.map(volume(from:)))
        }
    }

    private static func volume(from entry: [String: Any]) throws -> Volume {
        guard let device = entry["DeviceIdentifier"] as? String,
              let used = entry["CapacityInUse"] as? NSNumber
        else { throw LedgerError.malformed }
        return Volume(device: device,
                      // An unnamed volume is legal; a nameless row in the UI is not.
                      name: entry["Name"] as? String ?? device,
                      roles: entry["Roles"] as? [String] ?? [],
                      usedBytes: used.int64Value)
    }

    public static func snapshots(fromPlist data: Data) throws -> [Snapshot] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entries = (root as? [String: Any])?["Snapshots"] as? [[String: Any]]
        else { throw LedgerError.malformed }

        return try entries.map { entry in
            guard let uuid = entry["SnapshotUUID"] as? String,
                  let name = entry["SnapshotName"] as? String,
                  let xid = entry["SnapshotXID"] as? NSNumber
            else { throw LedgerError.malformed }
            return Snapshot(uuid: uuid,
                            name: name,
                            xid: xid.uint64Value,
                            isPurgeable: entry["Purgeable"] as? Bool ?? false)
        }
    }
}
