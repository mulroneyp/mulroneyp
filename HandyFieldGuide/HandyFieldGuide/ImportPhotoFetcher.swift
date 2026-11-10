import Foundation

/// Batch Commons photo fetch after an eBird import, with progress + ETA + cancel.
@MainActor
final class ImportPhotoFetcher: ObservableObject, Identifiable {
    let id = UUID()

    enum Phase: Equatable {
        case idle
        case running
        case cancelled
        case finished
    }

    struct WorkItem: Identifiable, Hashable {
        var id: String { speciesId }
        var speciesId: String
        var commonName: String
        var scientificName: String
        var aliases: [String]
        var alsoCalled: [String]
        var alsoScientific: [String]
        var dimorphic: Bool
        var roles: [String]
        var frequency: Double
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var completed: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var fetchedCount: Int = 0
    @Published private(set) var skippedCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    @Published private(set) var currentName: String = ""
    @Published private(set) var estimatedSecondsRemaining: TimeInterval?
    @Published private(set) var statusMessage: String = ""

    var isActive: Bool { phase == .running }
    var fractionComplete: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    private let photoCache: PhotoCacheStore
    private let client: CommonsPhotoClient
    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var durations: [TimeInterval] = []

    init(photoCache: PhotoCacheStore, client: CommonsPhotoClient = .shared) {
        self.photoCache = photoCache
        self.client = client
    }

    func cancel() {
        guard phase == .running else { return }
        task?.cancel()
        phase = .cancelled
        statusMessage = "Stopped. Photos already saved stay on this device."
        estimatedSecondsRemaining = nil
    }

    func dismissFinished() {
        if phase == .finished || phase == .cancelled {
            phase = .idle
        }
    }

    /// Builds work for species lacking local (bundled or cached) photos. Highest-frequency first.
    static func workItems(
        for record: ImportedLocationRecord,
        catalog: SpeciesCatalog,
        photoCache: PhotoCacheStore,
        monthIndex: Int
    ) -> [WorkItem] {
        var items: [WorkItem] = []
        for taxon in record.species where taxon.kind == .species {
            var species = catalog.resolvedSpecies(
                for: taxon,
                locationLabel: record.name,
                monthIndex: monthIndex
            )
            // Apply cache before deciding gaps so we do not re-download across locations.
            photoCache.applyCachedPhotos(to: &species)
            let roles = neededRoles(for: species)
            guard !roles.isEmpty else { continue }
            if photoCache.hasSatisfyingPhotos(for: species, roles: roles) {
                continue
            }
            items.append(
                WorkItem(
                    speciesId: species.id,
                    commonName: species.commonName,
                    scientificName: species.scientificName,
                    aliases: species.aliases,
                    alsoCalled: species.alsoCalled,
                    alsoScientific: species.alsoScientific,
                    dimorphic: species.dimorphic,
                    roles: roles,
                    frequency: taxon.mean(monthIndex: monthIndex)
                )
            )
        }
        return items.sorted {
            if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
            return $0.commonName < $1.commonName
        }
    }

    static func neededRoles(for species: Species) -> [String] {
        let have = Set(species.photos.map(\.role))
        if species.dimorphic {
            var roles: [String] = []
            if !have.contains("male") { roles.append("male") }
            if !have.contains("female") { roles.append("female") }
            return roles
        }
        if have.isEmpty {
            return ["either"]
        }
        return []
    }

    func start(items: [WorkItem]) {
        task?.cancel()
        completed = 0
        fetchedCount = 0
        skippedCount = 0
        failedCount = 0
        total = items.count
        estimatedSecondsRemaining = nil
        durations = []
        currentName = ""
        guard !items.isEmpty else {
            phase = .finished
            statusMessage = "Every imported species already has a local photo."
            return
        }
        phase = .running
        statusMessage = "Looking up open-licence photos…"
        startedAt = Date()
        task = Task { [weak self] in
            await self?.run(items: items)
        }
    }

    private func run(items: [WorkItem]) async {
        for item in items {
            if Task.isCancelled {
                phase = .cancelled
                statusMessage = "Stopped. Photos already saved stay on this device."
                estimatedSecondsRemaining = nil
                return
            }
            currentName = item.commonName
            let stepStart = Date()
            do {
                let saved = try await fetchOne(item)
                if saved > 0 {
                    fetchedCount += saved
                } else {
                    skippedCount += 1
                }
            } catch is CancellationError {
                phase = .cancelled
                statusMessage = "Stopped. Photos already saved stay on this device."
                estimatedSecondsRemaining = nil
                return
            } catch {
                failedCount += 1
            }
            completed += 1
            let elapsed = Date().timeIntervalSince(stepStart)
            durations.append(elapsed)
            updateETA()
        }
        phase = .finished
        estimatedSecondsRemaining = 0
        currentName = ""
        statusMessage = summaryMessage()
    }

    private func fetchOne(_ item: WorkItem) async throws -> Int {
        try Task.checkCancellation()

        var scientific = item.scientificName
        if scientific == "—" || scientific.isEmpty || scientific == "-" {
            scientific = await client.resolveScientificName(commonName: item.commonName, hinted: item.scientificName)
        }

        let query = CommonsPhotoClient.SpeciesQuery(
            commonName: item.commonName,
            scientificName: scientific,
            alsoCalled: item.alsoCalled,
            alsoScientific: item.alsoScientific,
            aliases: item.aliases
        )

        var avoid = Set<String>()
        var savedPhotos: [Photo] = []

        // Dimorphic: try male + female; fall back to a single unsexed photo if both miss.
        if item.dimorphic, item.roles.contains(where: { $0 == "male" || $0 == "female" }) {
            for role in item.roles {
                try Task.checkCancellation()
                if let photo = try await downloadRole(speciesId: item.speciesId, commonName: item.commonName, role: role, query: query, avoid: &avoid) {
                    savedPhotos.append(photo)
                }
            }
            if savedPhotos.isEmpty {
                if let photo = try await downloadRole(speciesId: item.speciesId, commonName: item.commonName, role: "unsexed", query: query, avoid: &avoid) {
                    savedPhotos.append(photo)
                }
            }
        } else {
            // Monomorphic / stub: prefer either, then unsexed.
            for role in ["either", "unsexed"] {
                try Task.checkCancellation()
                if let photo = try await downloadRole(speciesId: item.speciesId, commonName: item.commonName, role: role, query: query, avoid: &avoid) {
                    savedPhotos.append(photo)
                    break
                }
            }
        }

        guard !savedPhotos.isEmpty else { return 0 }
        photoCache.savePhotos(
            speciesId: item.speciesId,
            commonName: item.commonName,
            scientificName: scientific.isEmpty ? nil : scientific,
            dimorphic: item.dimorphic,
            photos: savedPhotos
        )
        return savedPhotos.count
    }

    private func downloadRole(
        speciesId: String,
        commonName: String,
        role: String,
        query: CommonsPhotoClient.SpeciesQuery,
        avoid: inout Set<String>
    ) async throws -> Photo? {
        // Skip network if this role is already on disk.
        if let existing = photoCache.entry(forSpeciesId: speciesId)?.photos.first(where: { $0.role == role }),
           photoCache.relativePathExists(existing.src) {
            avoid.insert(existing.file)
            return existing
        }

        guard let candidate = try await client.choosePhoto(species: query, role: role, avoidTitles: avoid) else {
            return nil
        }
        avoid.insert(candidate.title)
        let (data, width, height) = try await client.downloadJPEG(from: candidate.downloadURL)
        try Task.checkCancellation()
        let path = try photoCache.writeImageData(data, speciesId: speciesId, role: role)
        return CommonsPhotoClient.makePhoto(
            speciesId: speciesId,
            commonName: commonName,
            role: role,
            candidate: candidate,
            relativePath: path,
            width: width,
            height: height
        )
    }

    private func updateETA() {
        let remaining = total - completed
        guard remaining > 0 else {
            estimatedSecondsRemaining = 0
            return
        }
        // Prefer a short rolling average so early slow Wikidata lookups do not dominate forever.
        let window = durations.suffix(8)
        guard !window.isEmpty else {
            estimatedSecondsRemaining = nil
            return
        }
        let avg = window.reduce(0, +) / Double(window.count)
        estimatedSecondsRemaining = avg * Double(remaining)
    }

    private func summaryMessage() -> String {
        var parts: [String] = []
        if fetchedCount > 0 {
            parts.append("Saved \(fetchedCount) new photo\(fetchedCount == 1 ? "" : "s")")
        }
        if skippedCount > 0 {
            parts.append("\(skippedCount) without an open-licence match")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) network miss\(failedCount == 1 ? "" : "es")")
        }
        if parts.isEmpty {
            return "No new photos needed."
        }
        return parts.joined(separator: " · ") + "."
    }

    static func formatETA(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "Estimating time…" }
        if seconds <= 2 { return "Almost done" }
        if seconds < 60 {
            let s = max(1, Int(seconds.rounded()))
            return "About \(s) second\(s == 1 ? "" : "s") remaining"
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "About \(minutes) minute\(minutes == 1 ? "" : "s") remaining"
        }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 {
            return "About \(hours) hour\(hours == 1 ? "" : "s") remaining"
        }
        return "About \(hours) h \(rem) min remaining"
    }
}
