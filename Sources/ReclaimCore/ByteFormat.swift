import Foundation

/// How a byte count is read out to a person.
///
/// Finder, System Settings and every drive on sale divide by 1000. `du`, `ls -l`
/// and most developer tools divide by 1024. Both are defensible; dividing by
/// 1024 and printing "GB" is not — it puts this app 7% below the Finder window
/// beside it with no explanation, and a disk tool that disagrees with Finder is
/// a disk tool nobody believes.
public enum ByteFormat: String, Sendable, CaseIterable, Identifiable {
    /// Powers of 1000, labelled GB. What Finder shows.
    case decimal
    /// Powers of 1024, labelled GiB. What `du` counts.
    case binary

    public var id: String { rawValue }

    public var menuLabel: String {
        switch self {
        case .decimal: "Decimal — GB, like Finder"
        case .binary: "Binary — GiB, like du"
        }
    }

    private var step: Double { self == .decimal ? 1000 : 1024 }

    private var units: [String] {
        self == .decimal
            ? ["B", "KB", "MB", "GB", "TB", "PB"]
            : ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    }

    public func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = self.units
        var value = Double(bytes)
        var index = 0
        while value >= step && index < units.count - 1 {
            value /= step
            index += 1
        }
        return index == 0
            ? "\(Int(value)) B"
            : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[index])
    }
}
