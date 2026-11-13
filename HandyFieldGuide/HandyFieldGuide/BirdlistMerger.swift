import Foundation

/// Combines two or more saved eBird imports into one checklist.
///
/// **Frequency rule:** for the same species and the same month/week column, take the
/// **maximum** rate across sources — never sum. Adjacent hotspot barcharts observe the
/// same birds; adding rates would double-count.
enum BirdlistMerger {
    enum MergeError: LocalizedError {
        case needAtLeastTwo
        case emptyName
        case noSpecies

        var errorDescription: String? {
            switch self {
            case .needAtLeastTwo:
                return "Select at least two saved lists to merge."
            case .emptyName:
                return "Give the merged list a name."
            case .noSpecies:
                return "Those lists have no species to merge."
            }
        }
    }

    /// Builds a new `ImportedLocationRecord` from `records` without mutating the sources.
    static func merge(records: [ImportedLocationRecord], displayName: String) throws -> ImportedLocationRecord {
        guard records.count >= 2 else { throw MergeError.needAtLeastTwo }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MergeError.emptyName }

        var byKey: [String: Accumulator] = [:]
        byKey.reserveCapacity(records.reduce(0) { $0 + $1.species.count })

        for record in records {
            for taxon in record.species {
                let key = SpeciesCatalog.normalize(taxon.commonName)
                guard !key.isEmpty else { continue }
                if var existing = byKey[key] {
                    existing.merge(taxon)
                    byKey[key] = existing
                } else {
                    byKey[key] = Accumulator(taxon)
                }
            }
        }

        let species = byKey.values
            .map { $0.finished() }
            .sorted { $0.commonName.localizedCaseInsensitiveCompare($1.commonName) == .orderedAscending }

        guard !species.isEmpty else { throw MergeError.noSpecies }

        let sourceNames = records.map(\.name)
        let sourceFileLabel = "merged: " + sourceNames.joined(separator: ", ")
        let reported = species.count

        // Prefer coordinates from the first source that has them (caller orders
        // primary hotspot first for API multi-hotspot imports).
        let latitude = records.first(where: { $0.latitude != nil })?.latitude
        let longitude = records.first(where: { $0.longitude != nil })?.longitude

        return ImportedLocationRecord(
            id: "merged-\(UUID().uuidString.lowercased())",
            name: name,
            ebirdLocationId: nil,
            sourceFileName: sourceFileLabel,
            importedAt: Date(),
            reportedTaxonCount: reported,
            species: species,
            latitude: latitude,
            longitude: longitude
        )
    }

    // MARK: - Per-species accumulation

    private struct Accumulator {
        var commonName: String
        var kind: TaxonKind
        var monthlyMean: [Double]
        var monthlyMax: [Double]
        var weekFrequencies: [Double]
        var hasFullWeeks: Bool

        init(_ taxon: ImportedTaxonRecord) {
            commonName = taxon.commonName
            kind = taxon.kind
            monthlyMean = Self.padded(taxon.monthlyMean, count: 12)
            monthlyMax = Self.padded(taxon.monthlyMax, count: 12)
            if taxon.weekFrequencies.count >= 48 {
                weekFrequencies = Array(taxon.weekFrequencies.prefix(48))
                hasFullWeeks = true
            } else {
                weekFrequencies = Array(repeating: 0, count: 48)
                hasFullWeeks = false
            }
        }

        mutating func merge(_ taxon: ImportedTaxonRecord) {
            // Prefer a real species row over slash / sp. when names collide after normalize.
            if kind != .species && taxon.kind == .species {
                kind = .species
                commonName = taxon.commonName
            } else if kind == taxon.kind {
                // Keep the shorter / more standard spelling when equal kind.
                if taxon.commonName.count < commonName.count {
                    commonName = taxon.commonName
                }
            }

            let otherMean = Self.padded(taxon.monthlyMean, count: 12)
            let otherMax = Self.padded(taxon.monthlyMax, count: 12)
            for i in 0..<12 {
                monthlyMean[i] = max(monthlyMean[i], otherMean[i])
                monthlyMax[i] = max(monthlyMax[i], otherMax[i])
            }

            if taxon.weekFrequencies.count >= 48 {
                let otherWeeks = Array(taxon.weekFrequencies.prefix(48))
                if hasFullWeeks {
                    for i in 0..<48 {
                        weekFrequencies[i] = max(weekFrequencies[i], otherWeeks[i])
                    }
                } else {
                    weekFrequencies = otherWeeks
                    hasFullWeeks = true
                }
            }
        }

        func finished() -> ImportedTaxonRecord {
            if hasFullWeeks {
                var means: [Double] = []
                var maxes: [Double] = []
                means.reserveCapacity(12)
                maxes.reserveCapacity(12)
                for month in 0..<12 {
                    let slice = weekFrequencies[(month * 4)..<(month * 4 + 4)]
                    let weekMean = slice.reduce(0, +) / 4.0
                    let weekMax = slice.max() ?? 0
                    // Prefer week-column maxes; still honor a higher monthly-only source.
                    means.append(max(monthlyMean[month], weekMean))
                    maxes.append(max(monthlyMax[month], weekMax))
                }
                return ImportedTaxonRecord(
                    commonName: commonName,
                    kind: kind,
                    monthlyMean: means,
                    monthlyMax: maxes,
                    weekFrequencies: weekFrequencies
                )
            }

            return ImportedTaxonRecord(
                commonName: commonName,
                kind: kind,
                monthlyMean: monthlyMean,
                monthlyMax: monthlyMax,
                weekFrequencies: []
            )
        }

        private static func padded(_ values: [Double], count: Int) -> [Double] {
            if values.count >= count {
                return Array(values.prefix(count))
            }
            return values + Array(repeating: 0, count: count - values.count)
        }
    }
}
