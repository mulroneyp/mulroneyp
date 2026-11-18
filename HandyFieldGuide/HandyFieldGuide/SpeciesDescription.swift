import Foundation

/// Short field-guide line shown under the common name on bird detail (and in list rows).
/// Skips import plumbing, checklist %, and placeholder stubs — blank when unknown.
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

        return raw
    }

    static func hasText(for species: Species) -> Bool {
        !text(for: species).isEmpty
    }
}
