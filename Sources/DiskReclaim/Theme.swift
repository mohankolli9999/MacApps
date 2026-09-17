import SwiftUI
import ReclaimCore

/// Two independent visual channels carry the two things worth knowing:
/// hue says which tool an artefact belongs to, surface says how recoverable it
/// is. Keeping recoverability out of hue means it survives colourblindness and
/// greyscale, and it lets saturation concentrate on what is actually actionable.
enum Theme {
    static let stage = Color(hex: 0x101A1E)
    static let stageEdge = Color(hex: 0x0A1215)
    static let ink = Color(hex: 0xE6EEF0)
    static let muted = Color(hex: 0x7E9199)
    static let hairline = Color(hex: 0x25373D)
    /// Reserved for the one thing worth alarming about: a record that cannot
    /// bring anything back. Never used decoratively.
    static let warn = Color(hex: 0xE0A05A)
    /// The other side of `warn`: space on offer rather than a risk being run.
    /// Its own value so that an offer never has to borrow the alarm colour.
    static let gain = Color(hex: 0x4FB08A)

    private static let ecosystem: [String: Color] = [
        "ollama.models": Color(hex: 0x6E7BE8),
        "huggingface.hub": Color(hex: 0xE8C547),
        "lmstudio.models": Color(hex: 0xC77DD6),
        "npm.cache": Color(hex: 0xD4574E),
        "homebrew.cache": Color(hex: 0xC98A2E),
        "pip.cache": Color(hex: 0x4FB08A),
        "gradle.caches": Color(hex: 0x4FA8A8),
        "xcode.deriveddata": Color(hex: 0x5B8DEF),
        "docker.volumes": Color(hex: 0x3C9BD6),
    ]

    static func hue(for id: String) -> Color {
        ecosystem[id] ?? muted
    }

    /// How present a block looks. Reclaimable mass reads as solid and lit;
    /// locked mass recedes toward the stage.
    static func fillOpacity(for tier: Tier) -> Double {
        switch tier {
        case .exact: 1.0
        case .costly: 0.50
        case .irreplaceable: 0.26
        case .unknown: 0.15
        }
    }

    static func label(for tier: Tier) -> String {
        switch tier {
        case .exact: "Free to refetch"
        case .costly: "Costs time to rebuild"
        case .irreplaceable: "Cannot be restored"
        case .unknown: "Not recognised"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// One setting, read by every size on screen. Observation is what makes the
/// toggle work: SwiftUI records the read this function makes during a body, so
/// changing the format redraws every label without threading it through them.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    var byteFormat: ByteFormat {
        didSet { UserDefaults.standard.set(byteFormat.rawValue, forKey: Self.key) }
    }

    private static let key = "byteFormat"

    private init() {
        byteFormat = ByteFormat(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "")
            ?? .decimal
    }
}

@MainActor
func humanBytes(_ bytes: Int64) -> String {
    Preferences.shared.byteFormat.string(bytes)
}
