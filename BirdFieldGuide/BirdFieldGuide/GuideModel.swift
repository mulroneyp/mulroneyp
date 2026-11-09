import Foundation

@MainActor
final class GuideModel: ObservableObject {
    @Published var guide: GuideFile?
    @Published var loadError: String?
    @Published var locationQuery: String {
        didSet { UserDefaults.standard.set(locationQuery, forKey: Self.storageKey) }
    }
    @Published var searchText = ""
    @Published var stratum = "all"

    static let storageKey = "guide.locationQuery"

    init() {
        locationQuery = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        do {
            guide = try GuideLoader.load()
        } catch {
            loadError = "The species list could not be read from the app."
        }
    }

    var place: ResolvedPlace? {
        guard let guide else { return nil }
        return LocationResolver.resolve(query: locationQuery, guide: guide)
    }

    func stratumInfo(_ id: String) -> StratumInfo? {
        guide?.strata.first { $0.id == id }
    }

    func groupLabel(_ id: String, coverage: Coverage) -> String {
        coverage.groups.first { $0.id == id }?.label ?? id
    }

    func filteredSpecies(in place: ResolvedPlace) -> [Species] {
        let words = LocationResolver.normalize(searchText).split(separator: " ").map(String.init)
        return place.coverage.species.filter { species in
            if stratum != "all" && !species.strata.contains(stratum) {
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
}
