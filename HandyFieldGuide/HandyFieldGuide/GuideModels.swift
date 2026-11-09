import Foundation

struct GuideFile: Decodable {
    var defaultCoverageId: String
    var strata: [StratumInfo]
    var coverages: [Coverage]
    var outside: [OutsidePlace]
}

struct StratumInfo: Decodable, Identifiable {
    var id: String
    var label: String
    var hint: String
}

struct Coverage: Decodable, Identifiable {
    var id: String
    var label: String
    var placeTitle: String
    var country: String
    var realm: String
    var summary: String
    var sampleNote: String?
    var aliases: [String]
    var groups: [BirdGroup]
    var districts: [District]
    var species: [Species]
}

struct BirdGroup: Decodable, Identifiable {
    var id: String
    var label: String
}

struct District: Decodable, Identifiable {
    var id: String
    var label: String
    var aliases: [String]
    var lead: String
    var groupOrder: [String]
    var groupNotes: [String: String]
}

struct OutsidePlace: Decodable {
    var names: [String]
    var closestCoverageId: String
    var because: String
}

struct Species: Decodable, Identifiable {
    var id: String
    var commonName: String
    var scientificName: String
    var aliases: [String]
    var alsoCalled: [String]
    var alsoScientific: [String]
    var tags: [String]
    var dimorphic: Bool
    var origin: String
    var status: String
    var group: String
    var strata: [String]
    /// Broad periods such as dawn / morning / midday / afternoon / dusk / night.
    /// Empty when not curated (common for sparse eBird-only stubs).
    var activeTimes: [String]
    var summary: String
    var habitat: String
    var sexes: String
    var stratumNote: String
    var photos: [Photo]
}

struct Photo: Decodable, Identifiable {
    var role: String
    var label: String
    var src: String
    var alt: String
    var width: Int
    var height: Int
    var author: String
    var license: String
    var licenseUrl: String
    var sourceUrl: String
    var file: String

    var id: String { src }
}

struct ResolvedPlace {
    var query: String
    var coverage: Coverage
    var district: District?
    var displayName: String
    var isOutside: Bool
    var notice: String?
    var imported: ImportedLocationRecord? = nil
    var monthIndex: Int = Calendar.current.component(.month, from: Date()) - 1
}

enum GuideLoader {
    static func load() throws -> GuideFile {
        let url = Bundle.main.url(forResource: "guide", withExtension: "json")
            ?? Bundle.main.url(forResource: "guide", withExtension: "json", subdirectory: "Resources")
        guard let url else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GuideFile.self, from: data)
    }
}
