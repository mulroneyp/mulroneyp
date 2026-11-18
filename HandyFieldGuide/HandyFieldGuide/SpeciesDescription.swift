import Foundation

/// Short appearance/ID line under the common name on bird detail (and list rows).
/// Sourced from `Species.summary`, which must describe the bird — plumage, shape,
/// distinctive marks — never habitat or where to find it (that stays in Where You Find It).
/// Skips import plumbing and blank/unknown — never invents text in the UI.
enum SpeciesDescription {
    static func text(for species: Species) -> String {
        let raw = species.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let lower = raw.lowercased()

        if lower.contains("field notes are a short placeholder") { return "" }
        if lower.contains("field notes are limited") { return "" }
        if lower == "high-frequency species on the imported ebird barchart." { return "" }
        if lower == "high-frequency species on the imported ebird barchart" { return "" }
        if lower.contains("% of complete checklists") { return "" }
        if lower.hasPrefix("rare or absent in the selected month") { return "" }
        if lower.contains("slash taxon from the ebird export") { return "" }
        if lower.contains("provisional “sp.” taxon") || lower.contains("provisional \"sp.\" taxon") {
            return ""
        }
        if lower.contains("until this species is curated") { return "" }

        // Legacy habitat leads mistakenly stored in summary (pre-appearance rewrite).
        if looksLikeHabitatProse(lower) { return "" }

        return raw
    }

    static func hasText(for species: Species) -> Bool {
        !text(for: species).isEmpty
    }

    /// Heuristic for old Monteverde-style habitat sentences accidentally bound under the name.
    private static func looksLikeHabitatProse(_ lower: String) -> Bool {
        let habitatLeads = [
            "edges, clearings",
            "garden and edge",
            "canopy and edge",
            "thickets and the forest edge",
            "flowers at the forest edge",
            "heliconia and other flowers",
            "noisy birds of the canopy",
            "on the san gerardo list",
            "children's eternal rainforest",
            "large park lakes",
            "grazes on grass beside",
            "the default duck of",
            "a november migrant",
            "a lucky find",
            "high-frequency species on the imported",
        ]
        return habitatLeads.contains { lower.contains($0) }
    }
}
