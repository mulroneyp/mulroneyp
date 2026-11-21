import Foundation

/// On-device cache of filled appearance/ID lines and published lengths for imported
/// taxa that still lack bundled field notes. Lives under Documents so it survives
/// cache purges and can be reused across locations (same pattern as photo cache).
@MainActor
final class SpeciesFieldCacheStore: ObservableObject {
    /// Bumps when entries change so the guide rebuilds list/detail rows.
    @Published private(set) var revision: Int = 0

    private struct CatalogFile: Codable {
        var version: Int
        var species: [String: CachedSpeciesFields]
    }

    struct CachedSpeciesFields: Codable, Hashable {
        var speciesId: String
        var commonName: String
        var scientificName: String?
        /// Appearance/ID line under the common name. Empty means “not filled yet”.
        var summary: String
        /// Published total length in centimetres. Empty means “not filled yet”.
        var lengthCm: [Double]
        var updatedAt: Date
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var bySpeciesId: [String: CachedSpeciesFields] = [:]
    private var byNormalizedName: [String: String] = [:]

    init() {
        load()
    }

    var rootDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("species-fields", isDirectory: true)
    }

    private var catalogURL: URL {
        rootDirectory.appendingPathComponent("catalog.json")
    }

    func entry(forSpeciesId id: String) -> CachedSpeciesFields? {
        bySpeciesId[id]
    }

    func entry(forCommonName name: String) -> CachedSpeciesFields? {
        guard let id = byNormalizedName[SpeciesCatalog.normalize(name)] else { return nil }
        return bySpeciesId[id]
    }

    /// Fills blank `summary` / `lengthCm` from cache without overwriting curated text.
    func applyCachedFields(to species: inout Species) {
        guard let cached = entry(forSpeciesId: species.id) ?? entry(forCommonName: species.commonName) else {
            return
        }

        if !SpeciesDescription.hasText(for: species) {
            let candidate = cached.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                species.summary = candidate
            }
        }

        if !BirdSize.hasLength(species),
           !cached.lengthCm.isEmpty,
           !BirdSize.line(for: cached.lengthCm).isEmpty {
            species.lengthCm = cached.lengthCm
        }

        if let scientific = cached.scientificName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !scientific.isEmpty,
           scientific != "—",
           scientific != "-",
           (species.scientificName == "—" || species.scientificName.isEmpty || species.scientificName == "-") {
            species.scientificName = scientific
        }
    }

    /// Merges newly looked-up fields. Empty inputs leave the previous value alone.
    @discardableResult
    func saveFields(
        speciesId: String,
        commonName: String,
        scientificName: String?,
        summary: String?,
        lengthCm: [Double]?
    ) -> CachedSpeciesFields {
        ensureDirectory()
        var entry = bySpeciesId[speciesId] ?? CachedSpeciesFields(
            speciesId: speciesId,
            commonName: commonName,
            scientificName: scientificName,
            summary: "",
            lengthCm: [],
            updatedAt: Date()
        )
        entry.commonName = commonName
        if let scientificName {
            let trimmed = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "—", trimmed != "-" {
                entry.scientificName = trimmed
            }
        }
        if let summary {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                entry.summary = trimmed
            }
        }
        if let lengthCm, !lengthCm.isEmpty, lengthCm.allSatisfy({ $0 > 0 }) {
            entry.lengthCm = lengthCm
        }
        entry.updatedAt = Date()

        bySpeciesId[speciesId] = entry
        byNormalizedName[SpeciesCatalog.normalize(commonName)] = speciesId
        persist()
        revision += 1
        return entry
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func load() {
        ensureDirectory()
        guard FileManager.default.fileExists(atPath: catalogURL.path),
              let data = try? Data(contentsOf: catalogURL),
              let file = try? decoder.decode(CatalogFile.self, from: data) else {
            return
        }
        bySpeciesId = file.species
        byNormalizedName = Dictionary(uniqueKeysWithValues: file.species.values.map {
            (SpeciesCatalog.normalize($0.commonName), $0.speciesId)
        })
    }

    private func persist() {
        ensureDirectory()
        let file = CatalogFile(version: 1, species: bySpeciesId)
        do {
            let data = try encoder.encode(file)
            try data.write(to: catalogURL, options: [.atomic])
        } catch {
            // Keep in-memory cache for the session if disk write fails.
        }
    }
}
