import Foundation

/// Looks up field notes and photos for imported eBird common names.
/// Prefers the bundled guide coverages, then an optional supplemental catalog
/// built offline for high-frequency taxa at imported hotspots.
struct SpeciesCatalog {
    private var byNormalizedName: [String: Species]

    init(guide: GuideFile, supplemental: [Species] = []) {
        var map: [String: Species] = [:]
        for coverage in guide.coverages {
            for species in coverage.species {
                Self.index(species, into: &map)
            }
        }
        for species in supplemental {
            Self.index(species, into: &map)
        }
        byNormalizedName = map
    }

    static func loadSupplemental() -> [Species] {
        let names = [
            Bundle.main.url(forResource: "ebird_supplemental", withExtension: "json", subdirectory: "Resources"),
            Bundle.main.url(forResource: "ebird_supplemental", withExtension: "json"),
            Bundle.main.url(forResource: "ebird_supplemental", withExtension: "json", subdirectory: "Resources/catalog"),
            Bundle.main.url(forResource: "ebird_supplemental", withExtension: "json", subdirectory: "catalog"),
        ]
        guard let url = names.compactMap({ $0 }).first else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Species].self, from: data)
        } catch {
            return []
        }
    }

    func species(forCommonName name: String) -> Species? {
        byNormalizedName[Self.normalize(name)]
    }

    func resolvedSpecies(
        for taxon: ImportedTaxonRecord,
        locationLabel: String,
        monthIndex: Int
    ) -> Species {
        let frequency = taxon.mean(monthIndex: monthIndex)
        let percent = Int((frequency * 100).rounded())
        if let existing = species(forCommonName: taxon.commonName) {
            var copy = existing
            if taxon.kind != .species {
                copy.tags = Array(Set(copy.tags + ["flagged-taxon"]))
                copy.status = taxon.kind == .slash ? "slash taxon" : "sp. taxon"
            }
            return copy
        }

        let slug = Self.slug(taxon.commonName)
        let summary: String
        let habitat: String
        switch taxon.kind {
        case .species:
            summary = frequency > 0
                ? "About \(percent)% of complete checklists in the selected month."
                : "Rare or absent in the selected month on this eBird export."
            habitat = "Imported from the eBird frequency export for \(locationLabel). Field notes are limited until this species is curated; look it up by the common name on the list."
        case .slash:
            summary = "Slash taxon from the eBird export — not a single species."
            habitat = "eBird observers could not separate two similar species. Handy Field Guide keeps the row for completeness but does not invent an identification."
        case .provisionalSp:
            summary = "Provisional “sp.” taxon from the eBird export."
            habitat = "Observers reported a bird only to genus or a broader group. It is flagged here and not treated as a species account."
        }

        return Species(
            id: "imported-\(slug)",
            commonName: taxon.commonName,
            scientificName: taxon.kind == .species ? "—" : "taxon not resolved",
            aliases: [],
            alsoCalled: [],
            alsoScientific: [],
            tags: taxon.kind == .species ? ["imported"] : ["imported", "flagged-taxon"],
            dimorphic: false,
            origin: "native",
            status: taxon.kind == .species ? "imported" : (taxon.kind == .slash ? "slash taxon" : "sp. taxon"),
            group: taxon.kind == .species ? "imported" : "flagged",
            strata: ["mid"],
            summary: summary,
            habitat: habitat,
            sexes: "Sexes not curated for this imported name yet.",
            stratumNote: "Height band not curated for this imported name; mid is a placeholder.",
            photos: []
        )
    }

    private static func index(_ species: Species, into map: inout [String: Species]) {
        map[normalize(species.commonName)] = species
        for alias in species.aliases + species.alsoCalled {
            let key = normalize(alias)
            if map[key] == nil {
                map[key] = species
            }
        }
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "grey", with: "gray")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func slug(_ value: String) -> String {
        normalize(value).replacingOccurrences(of: " ", with: "-")
    }
}
