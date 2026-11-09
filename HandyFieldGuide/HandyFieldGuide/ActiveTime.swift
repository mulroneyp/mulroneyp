import Foundation

/// Broad field periods for when a bird is most worth looking for.
/// Not clock times — eBird barcharts are monthly, not hourly.
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

    /// e.g. "Dawn · Morning"
    static func display(_ ids: [String]) -> String {
        orderedIds.filter { ids.contains($0) }.map(label(for:)).joined(separator: " · ")
    }

    static func rowLabel(for species: Species) -> String {
        let text = display(species.activeTimes)
        if text.isEmpty {
            return "Time not listed"
        }
        return text
    }

    static func detailCaption(for species: Species) -> String {
        let text = display(species.activeTimes)
        if text.isEmpty {
            return "Time of day is not curated for this name. eBird barcharts are monthly, not hourly, so the export does not say when in the day the bird is most likely."
        }
        return "Most likely: \(text). Broad field periods from typical habits, not precise clock times. eBird barcharts are monthly, not hourly."
    }
}
