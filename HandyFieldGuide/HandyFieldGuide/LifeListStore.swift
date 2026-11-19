import Foundation

struct LifeListEntry: Codable, Identifiable, Hashable {
    var id: String
    var commonName: String
    var scientificName: String
    var taxonOrder: Int?
    var category: String
    var count: String?
    var exotic: String?
    var countable: Bool
    var firstRecordedDate: String?
    var firstRecordedLocation: String?
    var firstLocId: String?
    var firstSubId: String?
    var lastRecordedDate: String?
    var lastRecordedLocation: String?
    var lastLocId: String?
    var lastSubId: String?
    /// Relative path for a user photo from the Photos library (`life-list-photos/…`).
    var localPhotoPath: String?

    var displayScientificName: String {
        let trimmed = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    var hasFirstRecorded: Bool {
        !(firstRecordedDate?.isEmpty ?? true) || !(firstRecordedLocation?.isEmpty ?? true)
    }

    var hasLastRecorded: Bool {
        !(lastRecordedDate?.isEmpty ?? true) || !(lastRecordedLocation?.isEmpty ?? true)
    }

    /// "15 Jan 2020 · Monteverde · CR-P" style line; empty parts omitted.
    static func recordedLine(date: String?, location: String?) -> String? {
        let parts = [date, location]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let trimmed, !trimmed.isEmpty else { return nil }
                return trimmed
            }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    var firstRecordedLine: String? {
        Self.recordedLine(date: firstRecordedDate, location: firstRecordedLocation)
    }

    var lastRecordedLine: String? {
        Self.recordedLine(date: lastRecordedDate, location: lastRecordedLocation)
    }
}

struct LifeListDocument: Codable, Hashable {
    var version: Int
    var sourceFileName: String?
    var importedAt: Date?
    var aggregatedFromMyData: Bool?
    var entries: [LifeListEntry]
}

/// Persistence for an imported eBird life list + per-entry Photos-library images.
///
/// **List JSON** follows the same Birdlists layout as imported locations:
/// iCloud Drive → Handy Field Guide → Birdlists → `life-list.json`, with a local
/// sandbox mirror under `Documents/Birdlists/`.
///
/// **User photos** stay in the app sandbox (`Documents/life-list-photos/`) so they
/// remain available offline without syncing large JPEGs through ubiquity Documents.
@MainActor
final class LifeListStore: ObservableObject {
    static let storeFileName = "life-list.json"
    static let photoDirectoryName = "life-list-photos"
    static let photoPathPrefix = "life-list-photos/"

    @Published private(set) var document: LifeListDocument = LifeListDocument(
        version: 1,
        sourceFileName: nil,
        importedAt: nil,
        aggregatedFromMyData: nil,
        entries: []
    )
    @Published private(set) var usesICloudDocuments = false
    /// Bumps when a user photo is written so list thumbs refresh.
    @Published private(set) var photoRevision: Int = 0

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
        document = load() ?? LifeListDocument(
            version: 1,
            sourceFileName: nil,
            importedAt: nil,
            aggregatedFromMyData: nil,
            entries: []
        )
        usesICloudDocuments = iCloudBirdlistsDirectory() != nil
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

    var entries: [LifeListEntry] { document.entries }
    var isEmpty: Bool { document.entries.isEmpty }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var localBirdlistsDirectory: URL {
        documentsDirectory.appendingPathComponent(ImportedLocationStore.birdlistsFolderName, isDirectory: true)
    }

    var photoDirectory: URL {
        documentsDirectory.appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
    }

    private var localStoreURL: URL {
        localBirdlistsDirectory.appendingPathComponent(Self.storeFileName)
    }

    var activeBirdlistsDirectory: URL {
        iCloudBirdlistsDirectory() ?? localBirdlistsDirectory
    }

    /// Replaces the life list from a parsed eBird CSV. Keeps user photos when the
    /// same common (+ scientific) name is still present after import. When the new
    /// file only carries a first-recorded sighting (classic life-list export), any
    /// previously stored last-recorded fields for matching species are preserved.
    @discardableResult
    func replace(from parsed: ParsedLifeList) -> LifeListDocument {
        let previousByKey = Dictionary(
            uniqueKeysWithValues: document.entries.map {
                (matchKey(common: $0.commonName, scientific: $0.scientificName), $0)
            }
        )

        let entries = parsed.entries.map { row -> LifeListEntry in
            let id = Self.stableID(
                common: row.commonName,
                scientific: row.scientificName,
                taxonOrder: row.taxonOrder
            )
            let key = matchKey(common: row.commonName, scientific: row.scientificName)
            let previous = previousByKey[key]

            var lastDate = row.lastRecordedDate
            var lastLocation = row.lastRecordedLocation
            var lastLocId = row.lastLocId
            var lastSubId = row.lastSubId
            // Classic life-list CSV only has first-seen Date/Location. Keep a prior
            // last-recorded pair from an earlier My Data (or Last*) import.
            if lastDate == nil && lastLocation == nil, let previous {
                lastDate = previous.lastRecordedDate
                lastLocation = previous.lastRecordedLocation
                lastLocId = previous.lastLocId
                lastSubId = previous.lastSubId
            }

            return LifeListEntry(
                id: id,
                commonName: row.commonName,
                scientificName: row.scientificName,
                taxonOrder: row.taxonOrder,
                category: row.category,
                count: row.count,
                exotic: row.exotic,
                countable: row.countable,
                firstRecordedDate: row.firstRecordedDate,
                firstRecordedLocation: row.firstRecordedLocation,
                firstLocId: row.firstLocId,
                firstSubId: row.firstSubId,
                lastRecordedDate: lastDate,
                lastRecordedLocation: lastLocation,
                lastLocId: lastLocId,
                lastSubId: lastSubId,
                localPhotoPath: previous?.localPhotoPath
            )
        }

        document = LifeListDocument(
            version: 1,
            sourceFileName: parsed.sourceFileName,
            importedAt: Date(),
            aggregatedFromMyData: parsed.aggregatedFromMyData,
            entries: entries
        )
        persist()
        return document
    }

    /// Updates last-recorded fields from a CSV without replacing the whole list.
    /// Useful after downloading Sightings Lists in “most recent” mode.
    @discardableResult
    func mergeLastRecorded(from parsed: ParsedLifeList) -> Int {
        var updated = 0
        let byKey = Dictionary(
            uniqueKeysWithValues: document.entries.enumerated().map {
                (matchKey(common: $0.element.commonName, scientific: $0.element.scientificName), $0.offset)
            }
        )
        for row in parsed.entries {
            let key = matchKey(common: row.commonName, scientific: row.scientificName)
            // Prefer explicit last fields; fall back to first/date columns from a
            // “most recent” life-list download (same Date/Location columns).
            let date = row.lastRecordedDate ?? row.firstRecordedDate
            let location = row.lastRecordedLocation ?? row.firstRecordedLocation
            let locId = row.lastLocId ?? row.firstLocId
            let subId = row.lastSubId ?? row.firstSubId
            guard date != nil || location != nil else { continue }
            guard let index = byKey[key] else { continue }
            document.entries[index].lastRecordedDate = date
            document.entries[index].lastRecordedLocation = location
            document.entries[index].lastLocId = locId
            document.entries[index].lastSubId = subId
            updated += 1
        }
        if updated > 0 {
            persist()
        }
        return updated
    }

    func clear() {
        let oldPaths = document.entries.compactMap(\.localPhotoPath)
        document = LifeListDocument(
            version: 1,
            sourceFileName: nil,
            importedAt: nil,
            aggregatedFromMyData: nil,
            entries: []
        )
        persist()
        for path in oldPaths {
            removePhotoFile(atRelativePath: path)
        }
        photoRevision += 1
    }

    /// Saves a JPEG from the Photos library against a life-list entry.
    @discardableResult
    func setPhoto(jpegData: Data, for entryID: String) throws -> LifeListEntry {
        guard let index = document.entries.firstIndex(where: { $0.id == entryID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        ensurePhotoDirectory()
        let previous = document.entries[index].localPhotoPath
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let filename = "\(entryID)-\(token).jpg"
        let url = photoDirectory.appendingPathComponent(filename)
        try jpegData.write(to: url, options: [.atomic])
        let relative = Self.photoPathPrefix + filename
        document.entries[index].localPhotoPath = relative
        persist()
        if let previous, previous != relative {
            removePhotoFile(atRelativePath: previous)
        }
        BundleImages.invalidate(path: relative)
        photoRevision += 1
        return document.entries[index]
    }

    func clearPhoto(for entryID: String) {
        guard let index = document.entries.firstIndex(where: { $0.id == entryID }) else { return }
        let previous = document.entries[index].localPhotoPath
        document.entries[index].localPhotoPath = nil
        persist()
        if let previous {
            removePhotoFile(atRelativePath: previous)
        }
        photoRevision += 1
    }

    func entry(id: String) -> LifeListEntry? {
        document.entries.first { $0.id == id }
    }

    // MARK: - Identity

    static func stableID(common: String, scientific: String, taxonOrder: Int?) -> String {
        let base = SpeciesCatalog.slug(common)
        let sci = SpeciesCatalog.slug(scientific)
        if let taxonOrder {
            return "life-\(taxonOrder)-\(base)"
        }
        if sci.isEmpty || sci == "-" {
            return "life-\(base)"
        }
        return "life-\(base)-\(sci)"
    }

    private func matchKey(common: String, scientific: String) -> String {
        SpeciesCatalog.normalize(common) + "|" + SpeciesCatalog.normalize(scientific)
    }

    // MARK: - Paths / iCloud

    private func iCloudBirdlistsDirectory() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: ImportedLocationStore.ubiquityContainerIdentifier
        ) else {
            return nil
        }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(ImportedLocationStore.birdlistsFolderName, isDirectory: true)
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: localBirdlistsDirectory, withIntermediateDirectories: true)
        if let iCloud = iCloudBirdlistsDirectory() {
            try? fm.createDirectory(at: iCloud, withIntermediateDirectories: true)
        }
        ensurePhotoDirectory()
    }

    private func ensurePhotoDirectory() {
        try? FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
    }

    private func load() -> LifeListDocument? {
        ensureDirectories()
        promoteLocalMirrorToICloudIfNeeded()
        usesICloudDocuments = iCloudBirdlistsDirectory() != nil
        return readStore(preferringICloud: true)
    }

    private func persist() {
        ensureDirectories()
        do {
            let data = try encoder.encode(document)
            try writeCoordinated(data: data, to: localStoreURL)
            if let iCloudURL = iCloudBirdlistsDirectory()?.appendingPathComponent(Self.storeFileName) {
                try writeCoordinated(data: data, to: iCloudURL)
                usesICloudDocuments = true
            } else {
                usesICloudDocuments = false
            }
        } catch {
            // Keep in-memory list for the session if disk write fails.
        }
    }

    private func handleUbiquityIdentityChange() {
        ensureDirectories()
        promoteLocalMirrorToICloudIfNeeded()
        usesICloudDocuments = iCloudBirdlistsDirectory() != nil
        if let loaded = readStore(preferringICloud: true) {
            document = loaded
        }
    }

    private func promoteLocalMirrorToICloudIfNeeded() {
        guard let iCloudDir = iCloudBirdlistsDirectory() else { return }
        let fm = FileManager.default
        let iCloudFile = iCloudDir.appendingPathComponent(Self.storeFileName)
        guard fm.fileExists(atPath: localStoreURL.path) else { return }

        let cloudHasData: Bool = {
            guard fm.fileExists(atPath: iCloudFile.path),
                  let doc = decodeDocument(at: iCloudFile) else { return false }
            return !doc.entries.isEmpty || doc.importedAt != nil
        }()
        if cloudHasData { return }

        do {
            let data = try Data(contentsOf: localStoreURL)
            try writeCoordinated(data: data, to: iCloudFile)
        } catch {
            // Stay on local mirror.
        }
    }

    private func readStore(preferringICloud: Bool) -> LifeListDocument? {
        var candidates: [URL] = []
        if preferringICloud, let iCloud = iCloudBirdlistsDirectory()?.appendingPathComponent(Self.storeFileName) {
            candidates.append(iCloud)
        }
        candidates.append(localStoreURL)

        for url in candidates {
            ensureLocalUbiquitousCopyIfNeeded(at: url)
            if let doc = decodeDocument(at: url) {
                if url != localStoreURL, let data = try? Data(contentsOf: url) {
                    try? writeCoordinated(data: data, to: localStoreURL)
                }
                return doc
            }
        }
        return nil
    }

    private func decodeDocument(at url: URL) -> LifeListDocument? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try readCoordinated(from: url)
            return try decoder.decode(LifeListDocument.self, from: data)
        } catch {
            return nil
        }
    }

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
            // Fall through to normal file IO.
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
        guard let data else { throw CocoaError(.fileReadNoSuchFile) }
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

    private func removePhotoFile(atRelativePath path: String) {
        guard path.hasPrefix(Self.photoPathPrefix) else { return }
        let file = String(path.dropFirst(Self.photoPathPrefix.count))
        let url = photoDirectory.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: url)
        BundleImages.invalidate(path: path)
    }
}
