import Foundation

enum Likelihood {
    /// Plain likelihood wording for the UI. Never returns “Tier N” labels.
    static func label(for species: Species, frequency: Double? = nil) -> String {
        if let frequency {
            return fromFrequency(frequency)
        }
        return fromStatus(species.status)
    }

    static func fromFrequency(_ value: Double) -> String {
        if value >= 0.50 { return "Near-certain" }
        if value >= 0.15 { return "Likely" }
        if value >= 0.05 { return "Possible" }
        if value >= EBirdBarchartParser.nearZeroThreshold { return "Scarce" }
        return "Unlikely"
    }

    static func fromStatus(_ status: String) -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Possible" }

        // "Tier 2 · Likely" / "Tier 1 · Near-certain" → take the wording after the dot.
        if let dot = trimmed.range(of: "·") {
            let plain = trimmed[dot.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                return plain
            }
        }

        // Bare "Tier 3" style strings should never appear.
        if trimmed.range(of: #"^Tier\s*\d+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "Possible"
        }

        return trimmed
    }
}
