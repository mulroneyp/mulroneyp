import Combine
import Foundation

@MainActor
final class GuideModel: ObservableObject {
    @Published var guide: GuideFile?
    @Published var loadError: String?
    @Published var locationQuery: String {
        didSet {
            UserDefaults.standard.set(locationQuery, forKey: Self.storageKey)
            invalidatePlaceCache()
        }
    }
    /// Debounced search query used for filtering. Typing updates this after a short delay.
    @Published var searchText = ""
    /// Selected habitat zones. Empty means Any (no zone filter). Matching is OR across selections.
    @Published var selectedStrata: Set<String> = []
    /// 0 = January … 11 = December. Defaults to the device’s current month.
    @Published var selectedMonthIndex: Int
    @Published var hideNearZero = true
    @Published var showFlaggedTaxa = false {
        didSet { invalidatePlaceCache() }
    }
    @Published var importMessage: String?
    /// Active on-import Commons photo download (progress UI). Nil when idle.
    @Published var photoFetch: ImportPhotoFetcher?

    let imports = ImportedLocationStore()
    let photoCache = PhotoCacheStore()
    private(set) var catalog: SpeciesCatalog?
    private var importsCancellable: AnyCancellable?
    private var photoCacheCancellable: AnyCancellable?

    /// Cached resolved place so list / filter / navigation do not rebuild coverage every body pass.
    private var placeCache: PlaceCache? = nil

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
        importsCancellable = imports.objectWillChange.sink { [weak self] _ in
            self?.invalidatePlaceCache()
            self?.objectWillChange.send()
        }
        photoCacheCancellable = photoCache.$revision.sink { [weak self] _ in
            self?.invalidatePlaceCache()
            self?.objectWillChange.send()
        }
        Task { await self.loadGuideAndCatalog() }
    }

    private func loadGuideAndCatalog() async {
        do {
            let loaded = try await Self.decodeBundledGuide()
            guide = loaded.guide
            catalog = SpeciesCatalog(guide: loaded.guide, supplemental: loaded.supplemental, photoCache: photoCache)
            invalidatePlaceCache()
            // Drop saved queries that no longer match an import (old curated presets).
            // didSet does not run during init, so write UserDefaults explicitly.
            if !locationQuery.isEmpty, imports.location(matchingQuery: locationQuery) == nil {
                locationQuery = ""
                UserDefaults.standard.set("", forKey: Self.storageKey)
            }
        } catch {
            loadError = "The species list could not be read from the app."
        }
    }

    /// Read + decode large JSON off the main actor so launch stays responsive.
    private nonisolated static func decodeBundledGuide() async throws -> (guide: GuideFile, supplemental: [Species]) {
        try await Task.detached(priority: .userInitiated) {
            let guide = try GuideLoader.load()
            let supplemental = SpeciesCatalog.loadSupplemental()
            return (guide, supplemental)
        }.value
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
        invalidatePlaceCache()
    }

    func resetMonthToDevice() {
        setMonthIndex(Calendar.current.component(.month, from: Date()) - 1)
    }

    func setHideNearZero(_ value: Bool) {
        hideNearZero = value
        UserDefaults.standard.set(value, forKey: Self.hideNearZeroKey)
    }

    /// Active place is only an imported eBird / user-added list. No curated fallback.
    var place: ResolvedPlace? {
        refreshedPlaceCache()?.place
    }

    var hasImportedLocations: Bool {
        !imports.locations.isEmpty
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
        guard place.imported != nil else { return nil }
        let cache = refreshedPlaceCache()
        let key = SpeciesCatalog.normalize(species.commonName)
        return cache?.frequencies[key]
    }

    func filteredSpecies(in place: ResolvedPlace) -> [Species] {
        let words = LocationResolver.normalize(searchText).split(separator: " ").map(String.init)
        let cache = refreshedPlaceCache()
        let frequencies = cache?.frequencies ?? [:]
        let haystacks = cache?.searchHaystacks ?? [:]
        let hideNearZero = hideNearZero
        let selectedStrata = selectedStrata
        let filteringByZone = isFilteringByZone

        return place.coverage.species.filter { species in
            if filteringByZone && !species.strata.contains(where: { selectedStrata.contains($0) }) {
                return false
            }
            if place.imported != nil, hideNearZero {
                let key = SpeciesCatalog.normalize(species.commonName)
                if let frequency = frequencies[key],
                   frequency < EBirdBarchartParser.nearZeroThreshold {
                    return false
                }
            }
            if words.isEmpty { return true }
            let hay = haystacks[species.id] ?? Self.makeSearchHaystack(for: species)
            return words.allSatisfy { hay.contains($0) }
        }
    }

    func sortedForDisplay(_ birds: [Species], place: ResolvedPlace) -> [Species] {
        guard place.imported != nil else {
            return birds.sorted { $0.commonName < $1.commonName }
        }
        let frequencies = refreshedPlaceCache()?.frequencies ?? [:]
        return birds
            .map { species -> (Species, Double) in
                let key = SpeciesCatalog.normalize(species.commonName)
                return (species, frequencies[key] ?? 0)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.commonName < rhs.0.commonName
            }
            .map(\.0)
    }

    @discardableResult
    func importBarchart(data: Data, sourceFileName: String, displayName: String?) throws -> ImportedLocationRecord {
        let parsed = try EBirdBarchartParser.parse(data: data, sourceFileName: sourceFileName)
        let record = imports.upsert(from: parsed, displayName: displayName)
        invalidatePlaceCache()
        locationQuery = record.name
        importMessage = "Imported \(parsed.species.count) taxa for \(record.name) (\(parsed.resolvableSpeciesCount) species; \(parsed.flaggedTaxonCount) flagged)."
        startPhotoFetch(for: record)
        return record
    }

    func importBundledSample() throws {
        guard let url = imports.bundledFixtureURL() else {
            throw EBirdBarchartParser.ParseError.empty
        }
        let data = try Data(contentsOf: url)
        try importBarchart(data: data, sourceFileName: url.lastPathComponent, displayName: nil)
    }

    /// Looks up open-licence Commons photos for imported species missing a local image.
    /// Import persistence already finished — cancel only stops remaining downloads.
    func startPhotoFetch(for record: ImportedLocationRecord) {
        guard let catalog else { return }
        photoFetch?.cancel()
        photoFetch = nil
        let items = ImportPhotoFetcher.workItems(
            for: record,
            catalog: catalog,
            photoCache: photoCache,
            monthIndex: selectedMonthIndex
        )
        // Nothing missing — keep the list quiet; bundled/cache already cover this import.
        guard !items.isEmpty else { return }

        let fetcher = ImportPhotoFetcher(photoCache: photoCache)
        // Defer so the Add location sheet can dismiss before the progress sheet presents.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self else { return }
            self.photoFetch = fetcher
            fetcher.start(items: items)
        }
    }

    func clearPhotoFetchIfIdle() {
        guard let photoFetch else { return }
        if photoFetch.phase == .finished || photoFetch.phase == .cancelled || photoFetch.phase == .idle {
            self.photoFetch = nil
        }
    }

    /// Renames a saved/imported location and keeps the active query in sync.
    func renameImportedLocation(_ id: String, to newName: String) {
        guard let previous = imports.locations.first(where: { $0.id == id }) else { return }
        imports.rename(id, to: newName)
        invalidatePlaceCache()
        guard let updated = imports.locations.first(where: { $0.id == id }) else { return }
        if LocationResolver.normalize(locationQuery) == LocationResolver.normalize(previous.name)
            || imports.location(matchingQuery: locationQuery)?.id == id {
            locationQuery = updated.name
        }
    }

    /// Deletes a saved/imported location after confirmation in the UI.
    func deleteImportedLocation(_ id: String) {
        let record = imports.locations.first(where: { $0.id == id })
        let wasActive = record.map { loc in
            imports.location(matchingQuery: locationQuery)?.id == loc.id
                || LocationResolver.normalize(locationQuery) == LocationResolver.normalize(loc.name)
        } ?? false
        imports.remove(id)
        invalidatePlaceCache()
        if wasActive {
            locationQuery = ""
            importMessage = nil
        }
    }

    // MARK: - Place cache

    private struct PlaceCacheKey: Equatable {
        var locationId: String
        var locationName: String
        var importedAt: Date
        var taxonCount: Int
        var monthIndex: Int
        var includeFlagged: Bool
        var query: String
    }

    private struct PlaceCache {
        var key: PlaceCacheKey
        var place: ResolvedPlace
        var frequencies: [String: Double]
        var searchHaystacks: [String: String]
    }

    private func invalidatePlaceCache() {
        placeCache = nil
    }

    private func placeCacheKey(for imported: ImportedLocationRecord) -> PlaceCacheKey {
        PlaceCacheKey(
            locationId: imported.id,
            locationName: imported.name,
            importedAt: imported.importedAt,
            taxonCount: imported.species.count,
            monthIndex: selectedMonthIndex,
            includeFlagged: showFlaggedTaxa,
            query: locationQuery
        )
    }

    @discardableResult
    private func refreshedPlaceCache() -> PlaceCache? {
        guard guide != nil, let catalog else { return nil }
        guard let imported = imports.location(matchingQuery: locationQuery) else {
            placeCache = nil
            return nil
        }
        let key = placeCacheKey(for: imported)
        if let placeCache, placeCache.key == key {
            return placeCache
        }

        let coverage = ImportedCoverageBuilder.coverage(
            for: imported,
            catalog: catalog,
            monthIndex: selectedMonthIndex,
            includeFlagged: showFlaggedTaxa
        )
        let place = ResolvedPlace(
            query: locationQuery,
            coverage: coverage,
            district: coverage.districts.first,
            displayName: imported.name,
            isOutside: false,
            notice: nil,
            imported: imported,
            monthIndex: selectedMonthIndex
        )

        var frequencies: [String: Double] = [:]
        frequencies.reserveCapacity(imported.species.count)
        for taxon in imported.species {
            frequencies[SpeciesCatalog.normalize(taxon.commonName)] = taxon.mean(monthIndex: selectedMonthIndex)
        }

        var haystacks: [String: String] = [:]
        haystacks.reserveCapacity(coverage.species.count)
        for species in coverage.species {
            haystacks[species.id] = Self.makeSearchHaystack(for: species)
        }

        let built = PlaceCache(
            key: key,
            place: place,
            frequencies: frequencies,
            searchHaystacks: haystacks
        )
        placeCache = built
        return built
    }

    /// Same fields as before — pre-normalized once per place build instead of per keystroke.
    private static func makeSearchHaystack(for species: Species) -> String {
        LocationResolver.normalize([
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
    }
}
