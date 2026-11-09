import Foundation

@MainActor
final class GuideModel: ObservableObject {
    @Published var guide: GuideFile?
    @Published var loadError: String?
    @Published var locationQuery: String {
        didSet { UserDefaults.standard.set(locationQuery, forKey: Self.storageKey) }
    }
    @Published var searchText = ""
    /// Selected height bands. Empty means Any (no zone filter). Matching is OR across selections.
    @Published var selectedStrata: Set<String> = []
    /// 0 = January … 11 = December. Defaults to the device’s current month.
    @Published var selectedMonthIndex: Int
    @Published var hideNearZero = true
    @Published var showFlaggedTaxa = false
    @Published var importMessage: String?

    let imports = ImportedLocationStore()
    private(set) var catalog: SpeciesCatalog?

    static let storageKey = "handy.locationQuery"
    static let monthKey = "handy.selectedMonthIndex"
    static let hideNearZeroKey = "handy.hideNearZero"

    init(now: Date = Date(), calendar: Calendar = .current) {
        locationQuery = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        if let stored = UserDefaults.standard.object(forKey: Self.monthKey) as? Int,
           (0..<12).contains(stored) {
            selectedMonthIndex = stored
        } else {
            selectedMonthIndex = calendar.component(.month, from: now) - 1
        }
        if UserDefaults.standard.object(forKey: Self.hideNearZeroKey) != nil {
            hideNearZero = UserDefaults.standard.bool(forKey: Self.hideNearZeroKey)
        }
        do {
            let guide = try GuideLoader.load()
            self.guide = guide
            catalog = SpeciesCatalog(guide: guide, supplemental: SpeciesCatalog.loadSupplemental())
        } catch {
            loadError = "The species list could not be read from the app."
        }
    }

    var selectedMonthName: String {
        Calendar.current.monthSymbols[selectedMonthIndex]
    }

    var isUsingDeviceMonth: Bool {
        let deviceMonth = Calendar.current.component(.month, from: Date()) - 1
        return selectedMonthIndex == deviceMonth
    }

    func setMonthIndex(_ index: Int) {
        guard (0..<12).contains(index) else { return }
        selectedMonthIndex = index
        UserDefaults.standard.set(index, forKey: Self.monthKey)
    }

    func resetMonthToDevice() {
        setMonthIndex(Calendar.current.component(.month, from: Date()) - 1)
    }

    func setHideNearZero(_ value: Bool) {
        hideNearZero = value
        UserDefaults.standard.set(value, forKey: Self.hideNearZeroKey)
    }

    var place: ResolvedPlace? {
        guard let guide else { return nil }
        if let imported = imports.location(matchingQuery: locationQuery), let catalog {
            let coverage = ImportedCoverageBuilder.coverage(
                for: imported,
                catalog: catalog,
                monthIndex: selectedMonthIndex,
                includeFlagged: showFlaggedTaxa
            )
            return ResolvedPlace(
                query: locationQuery,
                coverage: coverage,
                district: coverage.districts.first,
                displayName: imported.name,
                isOutside: false,
                notice: nil,
                imported: imported,
                monthIndex: selectedMonthIndex
            )
        }
        var resolved = LocationResolver.resolve(query: locationQuery, guide: guide)
        resolved.monthIndex = selectedMonthIndex
        return resolved
    }

    func stratumInfo(_ id: String) -> StratumInfo? {
        guide?.strata.first { $0.id == id }
    }

    var isFilteringByZone: Bool {
        !selectedStrata.isEmpty
    }

    func toggleStratum(_ id: String) {
        if selectedStrata.contains(id) {
            selectedStrata.remove(id)
        } else {
            selectedStrata.insert(id)
        }
    }

    func clearStrata() {
        selectedStrata = []
    }

    func groupLabel(_ id: String, coverage: Coverage) -> String {
        coverage.groups.first { $0.id == id }?.label ?? id
    }

    func frequency(for species: Species, in place: ResolvedPlace) -> Double? {
        guard let imported = place.imported else { return nil }
        let match = imported.species.first {
            SpeciesCatalog.normalize($0.commonName) == SpeciesCatalog.normalize(species.commonName)
        }
        return match?.mean(monthIndex: selectedMonthIndex)
    }

    func filteredSpecies(in place: ResolvedPlace) -> [Species] {
        let words = LocationResolver.normalize(searchText).split(separator: " ").map(String.init)
        return place.coverage.species.filter { species in
            if isFilteringByZone && !species.strata.contains(where: { selectedStrata.contains($0) }) {
                return false
            }
            if place.imported != nil, hideNearZero,
               let frequency = frequency(for: species, in: place),
               frequency < EBirdBarchartParser.nearZeroThreshold {
                return false
            }
            if words.isEmpty { return true }
            let hay = LocationResolver.normalize([
                species.commonName,
                species.scientificName,
                species.summary,
                species.habitat,
                species.status,
                species.aliases.joined(separator: " "),
                species.alsoCalled.joined(separator: " "),
                species.alsoScientific.joined(separator: " "),
                species.tags.joined(separator: " "),
            ].joined(separator: " "))
            return words.allSatisfy { hay.contains($0) }
        }
    }

    func sortedForDisplay(_ birds: [Species], place: ResolvedPlace) -> [Species] {
        guard place.imported != nil else {
            return birds.sorted { $0.commonName < $1.commonName }
        }
        return birds.sorted { lhs, rhs in
            let lf = frequency(for: lhs, in: place) ?? 0
            let rf = frequency(for: rhs, in: place) ?? 0
            if lf != rf { return lf > rf }
            return lhs.commonName < rhs.commonName
        }
    }

    @discardableResult
    func importBarchart(data: Data, sourceFileName: String, displayName: String?) throws -> ImportedLocationRecord {
        let parsed = try EBirdBarchartParser.parse(data: data, sourceFileName: sourceFileName)
        let record = imports.upsert(from: parsed, displayName: displayName)
        locationQuery = record.name
        importMessage = "Imported \(parsed.species.count) taxa for \(record.name) (\(parsed.resolvableSpeciesCount) species; \(parsed.flaggedTaxonCount) flagged)."
        return record
    }

    func importBundledSample() throws {
        guard let url = imports.bundledFixtureURL() else {
            throw EBirdBarchartParser.ParseError.empty
        }
        let data = try Data(contentsOf: url)
        try importBarchart(data: data, sourceFileName: url.lastPathComponent, displayName: nil)
    }
}
