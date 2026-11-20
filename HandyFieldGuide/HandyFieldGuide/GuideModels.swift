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
    /// Empty when unknown — UI omits Time of day rather than inventing from eBird months.
    var activeTimes: [String]
    var summary: String
    var habitat: String
    var sexes: String
    var stratumNote: String
    var photos: [Photo]
    /// Total length in centimetres, one value or a [min, max] range.
    /// Empty when no published length was available — the UI leaves size blank.
    var lengthCm: [Double]

    init(
        id: String,
        commonName: String,
        scientificName: String,
        aliases: [String],
        alsoCalled: [String],
        alsoScientific: [String],
        tags: [String],
        dimorphic: Bool,
        origin: String,
        status: String,
        group: String,
        strata: [String],
        activeTimes: [String],
        summary: String,
        habitat: String,
        sexes: String,
        stratumNote: String,
        photos: [Photo],
        lengthCm: [Double] = []
    ) {
        self.id = id
        self.commonName = commonName
        self.scientificName = scientificName
        self.aliases = aliases
        self.alsoCalled = alsoCalled
        self.alsoScientific = alsoScientific
        self.tags = tags
        self.dimorphic = dimorphic
        self.origin = origin
        self.status = status
        self.group = group
        self.strata = strata
        self.activeTimes = activeTimes
        self.summary = summary
        self.habitat = habitat
        self.sexes = sexes
        self.stratumNote = stratumNote
        self.photos = photos
        self.lengthCm = lengthCm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        commonName = try container.decode(String.self, forKey: .commonName)
        scientificName = try container.decode(String.self, forKey: .scientificName)
        aliases = try container.decode([String].self, forKey: .aliases)
        alsoCalled = try container.decode([String].self, forKey: .alsoCalled)
        alsoScientific = try container.decode([String].self, forKey: .alsoScientific)
        tags = try container.decode([String].self, forKey: .tags)
        dimorphic = try container.decode(Bool.self, forKey: .dimorphic)
        origin = try container.decode(String.self, forKey: .origin)
        status = try container.decode(String.self, forKey: .status)
        group = try container.decode(String.self, forKey: .group)
        strata = try container.decode([String].self, forKey: .strata)
        activeTimes = try container.decodeIfPresent([String].self, forKey: .activeTimes) ?? []
        summary = try container.decode(String.self, forKey: .summary)
        habitat = try container.decode(String.self, forKey: .habitat)
        sexes = try container.decode(String.self, forKey: .sexes)
        stratumNote = try container.decode(String.self, forKey: .stratumNote)
        photos = try container.decode([Photo].self, forKey: .photos)
        lengthCm = try container.decodeIfPresent([Double].self, forKey: .lengthCm) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, commonName, scientificName, aliases, alsoCalled, alsoScientific, tags
        case dimorphic, origin, status, group, strata, activeTimes, summary, habitat
        case sexes, stratumNote, photos, lengthCm
    }
}

struct Photo: Codable, Identifiable, Hashable {
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
    /// `"library"` when the user attached their own photo; absent for bundled / Commons.
    var origin: String? = nil

    var id: String { src }

    /// True when this slot shows a user-attached photo (Photos library or drag-and-drop).
    var isLibraryPhoto: Bool { origin == "library" }
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
