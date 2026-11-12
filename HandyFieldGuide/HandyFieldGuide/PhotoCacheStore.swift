import Foundation

/// On-device open-licence photos keyed by species id / scientific name.
/// Lives under Documents so Files can see them and they survive cache purges.
@MainActor
final class PhotoCacheStore: ObservableObject {
    static var pathPrefix: String { BundleImages.cachedPathPrefix }

    /// Bumps when photos are added so the guide can rebuild rows/detail.
    @Published private(set) var revision: Int = 0

    private struct CatalogFile: Codable {
        var version: Int
        var species: [String: CachedSpeciesPhotos]
    }

    struct CachedSpeciesPhotos: Codable, Hashable {
        var speciesId: String
        var commonName: String
        var scientificName: String?
        var dimorphic: Bool
        var photos: [Photo]
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

    private var bySpeciesId: [String: CachedSpeciesPhotos] = [:]
    private var byNormalizedName: [String: String] = [:]

    init() {
        load()
    }

    var rootDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("species-photos", isDirectory: true)
    }

    private var catalogURL: URL {
        rootDirectory.appendingPathComponent("catalog.json")
    }

    /// Absolute file URL for a `cached-images/...` relative path, if present on disk.
    func fileURL(forRelativePath path: String) -> URL? {
        guard path.hasPrefix(Self.pathPrefix) else { return nil }
        let file = String(path.dropFirst(Self.pathPrefix.count))
        let url = rootDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func entry(forSpeciesId id: String) -> CachedSpeciesPhotos? {
        bySpeciesId[id]
    }

    func entry(forCommonName name: String) -> CachedSpeciesPhotos? {
        guard let id = byNormalizedName[SpeciesCatalog.normalize(name)] else { return nil }
        return bySpeciesId[id]
    }

    /// True when disk already has every role we still need for this species.
    func hasSatisfyingPhotos(for species: Species, roles: [String]) -> Bool {
        let existing = Set((entry(forSpeciesId: species.id) ?? entry(forCommonName: species.commonName))?.photos.map(\.role) ?? [])
        let bundled = Set(species.photos.map(\.role))
        let have = existing.union(bundled)
        if roles.isEmpty { return !have.isEmpty }
        return roles.allSatisfy { role in
            if role == "either" || role == "unsexed" {
                return !have.isEmpty
            }
            return have.contains(role)
        }
    }

    /// Applies on-device cache photos, preferring them over bundled defaults for the same role
    /// (so a user-chosen replacement sticks after the catalog rebuilds).
    func applyCachedPhotos(to species: inout Species) {
        guard let cached = entry(forSpeciesId: species.id) ?? entry(forCommonName: species.commonName),
              !cached.photos.isEmpty else {
            return
        }
        let usable = cached.photos.filter { relativePathExists($0.src) }
        guard !usable.isEmpty else { return }

        if species.photos.isEmpty {
            species.photos = usable
            return
        }

        var byRole = Dictionary(uniqueKeysWithValues: species.photos.map { ($0.role, $0) })
        for photo in usable {
            byRole[photo.role] = photo
        }
        let order = ["male": 0, "female": 1, "either": 2, "unsexed": 3, "illustration": 4]
        let merged = Array(byRole.values).sorted {
            (order[$0.role] ?? 9, $0.label) < (order[$1.role] ?? 9, $1.label)
        }

        if species.dimorphic {
            species.photos = merged
            return
        }

        // Monomorphic: one photo. Prefer any cached role over the bundled default.
        if let preferred = usable.first(where: { $0.role == "either" || $0.role == "unsexed" })
            ?? usable.first {
            species.photos = [preferred]
        }
    }

    @discardableResult
    func savePhotos(
        speciesId: String,
        commonName: String,
        scientificName: String?,
        dimorphic: Bool,
        photos: [Photo]
    ) -> CachedSpeciesPhotos {
        ensureDirectory()
        var entry = bySpeciesId[speciesId] ?? CachedSpeciesPhotos(
            speciesId: speciesId,
            commonName: commonName,
            scientificName: scientificName,
            dimorphic: dimorphic,
            photos: [],
            updatedAt: Date()
        )
        entry.commonName = commonName
        if let scientificName, !scientificName.isEmpty, scientificName != "—" {
            entry.scientificName = scientificName
        }
        entry.dimorphic = dimorphic
        entry.updatedAt = Date()

        var byRole = Dictionary(uniqueKeysWithValues: entry.photos.map { ($0.role, $0) })
        for photo in photos {
            byRole[photo.role] = photo
        }
        entry.photos = Array(byRole.values).sorted { $0.role < $1.role }

        bySpeciesId[speciesId] = entry
        byNormalizedName[SpeciesCatalog.normalize(commonName)] = speciesId
        persist()
        revision += 1
        return entry
    }

    /// Writes JPEG bytes under Documents and returns a `cached-images/` relative path.
    /// Pass `token` when replacing an existing photo so the relative path changes and UI caches refresh.
    func writeImageData(_ data: Data, speciesId: String, role: String, token: String? = nil) throws -> String {
        ensureDirectory()
        let filename: String
        let suffix = token.map { "-\($0)" } ?? ""
        switch role {
        case "male", "female":
            filename = "\(speciesId)-\(role)\(suffix).jpg"
        default:
            filename = "\(speciesId)\(suffix).jpg"
        }
        let url = rootDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return Self.pathPrefix + filename
    }

    /// Removes a previous on-disk JPEG for a role when the relative path changes after a replacement.
    func removeImageFile(atRelativePath path: String) {
        guard let url = fileURL(forRelativePath: path) else { return }
        try? FileManager.default.removeItem(at: url)
        BundleImages.invalidate(path: path)
    }

    func relativePathExists(_ path: String) -> Bool {
        fileURL(forRelativePath: path) != nil
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
