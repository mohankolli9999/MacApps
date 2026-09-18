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
