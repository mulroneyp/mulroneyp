import Foundation

struct ImportedLocationRecord: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var ebirdLocationId: String?
    var sourceFileName: String
    var importedAt: Date
    var reportedTaxonCount: Int?
    var species: [ImportedTaxonRecord]
    /// Hotspot coordinates from eBird when known (API import / hotspot info).
    var latitude: Double? = nil
    var longitude: Double? = nil

    /// True for lists created by merging two or more saved imports.
    var isMerged: Bool {
        id.hasPrefix("merged-")
    }

    var hasCoordinates: Bool {
        latitude != nil && longitude != nil
    }

    var placeTitle: String {
        if isMerged {
            return "Merged checklist"
        }
        if let ebirdLocationId, !ebirdLocationId.isEmpty {
            return "eBird \(ebirdLocationId)"
        }
        return "Imported checklist"
    }
}

struct ImportedTaxonRecord: Codable, Hashable, Identifiable {
    var commonName: String
    var kind: TaxonKind
    var monthlyMean: [Double]
    var monthlyMax: [Double]
    var weekFrequencies: [Double]

    var id: String { commonName }

    func mean(monthIndex: Int) -> Double {
        guard monthlyMean.indices.contains(monthIndex) else { return 0 }
        return monthlyMean[monthIndex]
    }
}

/// Persistence for imported eBird lists.
///
/// **Primary path (iCloud Documents):**
/// `…/Mobile Documents/iCloud.com.mulroneyp.handyfieldguide/Documents/Birdlists/imported-locations.json`
/// which surfaces in the Files app as **iCloud Drive → Handy Field Guide → Birdlists**.
///
/// Ubiquity Documents keep a **local on-device copy**. Opening an already-imported list
/// reads that local file and does **not** require network. The system syncs when online.
///
/// **Offline / unsigned-in fallback:** `Documents/Birdlists/` inside the app sandbox.
/// Writes always refresh that local mirror so lists remain readable if iCloud is later
/// unavailable or a ubiquitous item has not finished downloading. Legacy
/// `Documents/imported-locations.json` is migrated into Birdlists on first launch
/// (best effort; the legacy file is left in place if the destination write fails).
@MainActor
final class ImportedLocationStore: ObservableObject {
    static let ubiquityContainerIdentifier = "iCloud.com.mulroneyp.handyfieldguide"
    static let birdlistsFolderName = "Birdlists"
    static let storeFileName = "imported-locations.json"

    @Published private(set) var locations: [ImportedLocationRecord] = []
    /// Whether the active write target is the iCloud ubiquity Documents folder.
    @Published private(set) var usesICloudDocuments = false

    private let fileName = ImportedLocationStore.storeFileName
    private let birdlistsFolderName = ImportedLocationStore.birdlistsFolderName
    private let ubiquityContainerIdentifier = ImportedLocationStore.ubiquityContainerIdentifier
    private let migrationDefaultsKey = "ImportedLocationStore.migratedLegacyToBirdlists.v1"

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

    private var ubiquityObserver: NSObjectProtocol?

    init() {
        locations = load()
        ubiquityObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleUbiquityIdentityChange()
            }
        }
    }

    deinit {
        if let ubiquityObserver {
            NotificationCenter.default.removeObserver(ubiquityObserver)
        }
    }

    /// App sandbox Documents (file sharing / photo cache / sample fixture). Unchanged for photos.
    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Local mirror / offline fallback: `Documents/Birdlists/`.
    var localBirdlistsDirectory: URL {
        documentsDirectory.appendingPathComponent(birdlistsFolderName, isDirectory: true)
    }

    /// Ubiquity Documents/Birdlists when iCloud is available; otherwise the local Birdlists folder.
    var activeBirdlistsDirectory: URL {
        if let iCloud = iCloudBirdlistsDirectory() {
            return iCloud
        }
        return localBirdlistsDirectory
    }

    private var legacyStoreURL: URL {
        documentsDirectory.appendingPathComponent(fileName)
    }

    private var localStoreURL: URL {
        localBirdlistsDirectory.appendingPathComponent(fileName)
    }

    private var activeStoreURL: URL {
        activeBirdlistsDirectory.appendingPathComponent(fileName)
    }

    func location(matchingQuery query: String) -> ImportedLocationRecord? {
        let needle = LocationResolver.normalize(query)
        guard !needle.isEmpty else { return nil }
        return locations.first { location in
            let candidates = [
                location.name,
                location.id,
                location.ebirdLocationId ?? "",
                location.placeTitle,
            ]
            return candidates.contains { LocationResolver.normalize($0) == needle }
                || candidates.contains { LocationResolver.normalize($0).contains(needle) && needle.count >= 4 }
        }
    }

    @discardableResult
    func upsert(
        from parsed: ParsedBarchart,
        displayName: String?,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> ImportedLocationRecord {
        let locationId = parsed.ebirdLocationId
        let id = locationId.map { "ebird-\($0)" } ?? "ebird-\(UUID().uuidString.lowercased())"
        let defaultName = locationId ?? parsed.sourceFileName
        let name = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName
        let record = ImportedLocationRecord(
            id: id,
            name: name,
            ebirdLocationId: locationId,
            sourceFileName: parsed.sourceFileName,
            importedAt: Date(),
            reportedTaxonCount: parsed.reportedTaxonCount,
            species: parsed.species.map {
                ImportedTaxonRecord(
                    commonName: $0.commonName,
                    kind: $0.kind,
                    monthlyMean: $0.monthlyMean,
                    monthlyMax: $0.monthlyMax,
                    weekFrequencies: $0.weekFrequencies
                )
            },
            latitude: latitude,
            longitude: longitude
        )
        if let index = locations.firstIndex(where: { $0.id == record.id || ($0.ebirdLocationId != nil && $0.ebirdLocationId == record.ebirdLocationId) }) {
            // Keep prior coordinates when a re-import omits them (e.g. `.txt` replace).
            var merged = record
            if merged.latitude == nil { merged.latitude = locations[index].latitude }
            if merged.longitude == nil { merged.longitude = locations[index].longitude }
            locations[index] = merged
            persist()
            return merged
        } else {
            locations.append(record)
        }
        persist()
        return record
    }

    /// Persists a hand-built record (e.g. a merged checklist). Matches by `id` only —
    /// never by eBird L-code — so merges do not overwrite hotspot imports.
    @discardableResult
    func upsert(_ record: ImportedLocationRecord) -> ImportedLocationRecord {
        if let index = locations.firstIndex(where: { $0.id == record.id }) {
            locations[index] = record
        } else {
            locations.append(record)
        }
        persist()
        return record
    }

    /// Updates the display name for a saved import and writes the Birdlists store.
    func rename(_ id: String, to newName: String) {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        locations[index].name = trimmed
        persist()
    }

    /// Removes a saved import from the store. Does not delete the sample barchart
    /// fixture in the app bundle / Documents.
    func remove(_ id: String) {
        locations.removeAll { $0.id == id }
        persist()
    }

    private func load() -> [ImportedLocationRecord] {
        copyBundledFixtureIntoDocumentsIfNeeded()
        ensureBirdlistsDirectories()
        migrateLegacyStoreIfNeeded()
        promoteLocalMirrorToICloudIfNeeded()

        usesICloudDocuments = iCloudBirdlistsDirectory() != nil

        if let records = readStore(preferringICloud: true) {
            return records
        }
        return []
    }

    private func persist() {
        ensureBirdlistsDirectories()
        do {
            let data = try encoder.encode(locations)
            // Always refresh the local mirror first so offline open never depends on network.
            try writeCoordinated(data: data, to: localStoreURL)
            if let iCloudURL = iCloudBirdlistsDirectory()?.appendingPathComponent(fileName) {
                try writeCoordinated(data: data, to: iCloudURL)
                usesICloudDocuments = true
            } else {
                usesICloudDocuments = false
            }
        } catch {
            // Persistence failures leave the in-memory list intact for the session.
        }
    }

    private func handleUbiquityIdentityChange() {
        ensureBirdlistsDirectories()
        promoteLocalMirrorToICloudIfNeeded()
        usesICloudDocuments = iCloudBirdlistsDirectory() != nil
        if let records = readStore(preferringICloud: true) {
            locations = records
        }
    }

    // MARK: - Paths

    private func iCloudBirdlistsDirectory() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: ubiquityContainerIdentifier
        ) else {
            return nil
        }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(birdlistsFolderName, isDirectory: true)
    }

    private func ensureBirdlistsDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: localBirdlistsDirectory, withIntermediateDirectories: true)
        if let iCloud = iCloudBirdlistsDirectory() {
            try? fm.createDirectory(at: iCloud, withIntermediateDirectories: true)
        }
    }

    // MARK: - Migration

    /// Moves legacy `Documents/imported-locations.json` into Birdlists (iCloud when available,
    /// otherwise the local Birdlists folder). Does not delete the legacy file if the copy fails.
    private func migrateLegacyStoreIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyStoreURL.path) else {
            UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
            return
        }

        let destination: URL
        if let iCloudFile = iCloudBirdlistsDirectory()?.appendingPathComponent(fileName) {
            destination = iCloudFile
        } else {
            destination = localStoreURL
        }

        // Prefer existing Birdlists content; only seed from legacy when destination is empty.
        if fm.fileExists(atPath: destination.path),
           let existing = decodeRecords(at: destination),
           !existing.isEmpty {
            UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
            // Still seed the local mirror if missing.
            if destination != localStoreURL, !fm.fileExists(atPath: localStoreURL.path) {
                try? writeCoordinated(data: Data(contentsOf: destination), to: localStoreURL)
            }
            return
        }

        do {
            let data = try Data(contentsOf: legacyStoreURL)
            try writeCoordinated(data: data, to: destination)
            if destination != localStoreURL {
                try writeCoordinated(data: data, to: localStoreURL)
            }
            UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
            // Leave legacy in place as a safety copy; subsequent launches skip re-copy when destination has data.
        } catch {
            // Keep using legacy/local data; do not wipe.
        }
    }

    /// When iCloud becomes available, copy the local Birdlists mirror up if the cloud file is missing/empty.
    private func promoteLocalMirrorToICloudIfNeeded() {
        guard let iCloudDir = iCloudBirdlistsDirectory() else { return }
        let fm = FileManager.default
        let iCloudFile = iCloudDir.appendingPathComponent(fileName)
        let localFile = localStoreURL

        guard fm.fileExists(atPath: localFile.path) else { return }

        let cloudHasData: Bool = {
            guard fm.fileExists(atPath: iCloudFile.path),
                  let records = decodeRecords(at: iCloudFile) else { return false }
            return !records.isEmpty
        }()
        if cloudHasData { return }

        do {
            let data = try Data(contentsOf: localFile)
            try writeCoordinated(data: data, to: iCloudFile)
        } catch {
            // Stay on local mirror until iCloud accepts a write.
        }
    }

    // MARK: - Read / write

    private func readStore(preferringICloud: Bool) -> [ImportedLocationRecord]? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if preferringICloud, let iCloud = iCloudBirdlistsDirectory()?.appendingPathComponent(fileName) {
            candidates.append(iCloud)
        }
        candidates.append(localStoreURL)
        if fm.fileExists(atPath: legacyStoreURL.path) {
            candidates.append(legacyStoreURL)
        }

        for url in candidates {
            ensureLocalUbiquitousCopyIfNeeded(at: url)
            if let records = decodeRecords(at: url) {
                // If we loaded from iCloud, keep the local mirror current for offline.
                if url != localStoreURL, let data = try? Data(contentsOf: url) {
                    try? writeCoordinated(data: data, to: localStoreURL)
                }
                return records
            }
        }
        return nil
    }

    private func decodeRecords(at url: URL) -> [ImportedLocationRecord]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try readCoordinated(from: url)
            return try decoder.decode([ImportedLocationRecord].self, from: data)
        } catch {
            return nil
        }
    }

    /// Asks the system for a local ubiquity copy when the item exists in iCloud but is not yet
    /// downloaded. Already-local copies (normal after import on this device) return immediately
    /// and work with no network.
    private func ensureLocalUbiquitousCopyIfNeeded(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || fm.isUbiquitousItem(at: url) else { return }
        do {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
            guard values.isUbiquitousItem == true else { return }
            if values.ubiquitousItemDownloadingStatus != .current {
                try? fm.startDownloadingUbiquitousItem(at: url)
            }
        } catch {
            // Non-ubiquitous or unreadable resource values — fall through to normal file IO.
        }
    }

    private func readCoordinated(from url: URL) throws -> Data {
        var data: Data?
        var coordinationError: NSError?
        var readError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                data = try Data(contentsOf: readable)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let data else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    private func writeCoordinated(data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writable in
            do {
                try data.write(to: writable, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    /// Copies the bundled L436229 fixture into sandbox Documents so it appears under
    /// Files → On My iPhone → Handy Field Guide (not the iCloud Birdlists folder).
    @discardableResult
    func copyBundledFixtureIntoDocumentsIfNeeded() -> URL? {
        guard let url = bundledFixtureURL() else { return nil }
        let copyURL = documentsDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: copyURL.path) {
            return copyURL
        }
        do {
            try Data(contentsOf: url).write(to: copyURL, options: [.atomic])
            return copyURL
        } catch {
            return nil
        }
    }

    func bundledFixtureURL() -> URL? {
        Bundle.main.url(
            forResource: "ebird_L436229__2020_2026_1_12_barchart",
            withExtension: "txt",
            subdirectory: "fixtures"
        ) ?? Bundle.main.url(
            forResource: "ebird_L436229__2020_2026_1_12_barchart",
            withExtension: "txt",
            subdirectory: "Resources/fixtures"
        ) ?? Bundle.main.url(
            forResource: "ebird_L436229__2020_2026_1_12_barchart",
            withExtension: "txt"
        )
    }
}
