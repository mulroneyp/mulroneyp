import Foundation

enum ImportedCoverageBuilder {
    static let importedGroup = BirdGroup(id: "imported", label: "From eBird frequency")
    static let flaggedGroup = BirdGroup(id: "flagged", label: "Flagged taxa (sp. / slash)")

    @MainActor
    static func coverage(
        for record: ImportedLocationRecord,
        catalog: SpeciesCatalog,
        monthIndex: Int,
        includeFlagged: Bool
    ) -> Coverage {
        let taxa = record.species.filter { includeFlagged || $0.kind == .species }
        let species = taxa.map { catalog.resolvedSpecies(for: $0, locationLabel: record.name, monthIndex: monthIndex) }
        let monthName = Calendar.current.monthSymbols[monthIndex]
        let sample: String
        if record.isMerged {
            sample = """
            Merged checklist (\(record.sourceFileName)). \
            When the same species appears in more than one source, each week and month rate is the maximum across sources — rates are never summed. \
            The list below is filtered by \(monthName) on this device. \
            Species below \(percent(EBirdBarchartParser.nearZeroThreshold)) mean frequency for the selected month are hidden unless you show scarce birds. \
            Photos and habitat notes reuse the bundled guide when the common name matches; otherwise a supplemental Commons catalog and on-device open-licence downloads fill gaps, with stubs for the rest.
            """
        } else {
            sample = """
            Imported from \(record.sourceFileName). \
            Frequencies are the mean of eBird’s four week columns for each month. \
            The list below is filtered by \(monthName) on this device. \
            Species below \(percent(EBirdBarchartParser.nearZeroThreshold)) mean frequency for the selected month are hidden unless you show scarce birds. \
            Photos and habitat notes reuse the bundled guide when the common name matches; otherwise a supplemental Commons catalog and on-device open-licence downloads fill gaps, with stubs for the rest.
            """
        }
        let summary: String
        if record.isMerged {
            summary = "Merged eBird frequency checklist. \(record.species.count) taxa; \(record.resolvableCount) treated as species."
        } else {
            summary = "eBird frequency checklist\(record.ebirdLocationId.map { " for \($0)" } ?? ""). \(record.species.count) taxa in the file; \(record.resolvableCount) treated as species."
        }
        return Coverage(
            id: record.id,
            label: record.name,
            placeTitle: record.placeTitle,
            country: "Imported",
            realm: "ebird",
            summary: summary,
            sampleNote: sample,
            aliases: ([record.name, record.id, record.ebirdLocationId, record.placeTitle] as [String?]).compactMap { $0 }.filter { !$0.isEmpty },
            groups: [importedGroup, flaggedGroup],
            districts: [
                District(
                    id: "all",
                    label: record.name,
                    aliases: ([record.name, record.ebirdLocationId] as [String?]).compactMap { $0 },
                    lead: "Checklist frequencies from the imported eBird barchart.",
                    groupOrder: ["imported", "flagged"],
                    groupNotes: [:]
                )
            ],
            species: species
        )
    }

    private static func percent(_ value: Double) -> String {
        let pct = value * 100
        if pct >= 1 {
            return String(format: "%.0f%%", pct)
        }
        return String(format: "%.1f%%", pct)
    }
}

extension ImportedLocationRecord {
    var resolvableCount: Int {
        species.filter { $0.kind == .species }.count
    }
}
