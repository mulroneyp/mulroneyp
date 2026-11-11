import Foundation

/// Broad field periods for when a bird is most worth looking for.
/// Shown only when curated; never invented from monthly eBird columns.
enum ActiveTime {
    static let orderedIds = ["dawn", "morning", "midday", "afternoon", "dusk", "night"]

    static func label(for id: String) -> String {
        switch id {
        case "dawn": return "Dawn"
        case "morning": return "Morning"
        case "midday": return "Midday"
        case "afternoon": return "Afternoon"
        case "dusk": return "Dusk"
        case "night": return "Night"
        default: return id.capitalized
        }
    }

    /// e.g. "Dawn · Morning". Empty when no curated periods.
    static func display(_ ids: [String]) -> String {
        orderedIds.filter { ids.contains($0) }.map(label(for:)).joined(separator: " · ")
    }

    static func hasKnownTimes(for species: Species) -> Bool {
        !display(species.activeTimes).isEmpty
    }

    /// List-row chip; empty string when unknown so callers can hide it.
    static func rowLabel(for species: Species) -> String {
        display(species.activeTimes)
    }

    /// Detail body when times are known. Call only after `hasKnownTimes`.
    static func detailCaption(for species: Species) -> String {
        let text = display(species.activeTimes)
        return "Most likely: \(text). Broad field periods from typical habits, not precise clock times."
    }
}
