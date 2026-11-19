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
    /// ISO country code from eBird S/P / location (e.g. `US` from `US-TX`).
    var firstRecordedCountryCode: String?
    var lastRecordedDate: String?
    var lastRecordedLocation: String?
    var lastLocId: String?
    var lastSubId: String?
    var lastRecordedCountryCode: String?
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

    /// Country codes from stored fields or derived from location labels (for older imports).
    var countryCodes: Set<String> {
        var codes = Set<String>()
        if let code = resolvedCountryCode(
            stored: firstRecordedCountryCode,
            location: firstRecordedLocation
        ) {
            codes.insert(code)
        }
        if let code = resolvedCountryCode(
            stored: lastRecordedCountryCode,
            location: lastRecordedLocation
        ) {
            codes.insert(code)
        }
        return codes
    }

    func matchesCountryCode(_ code: String) -> Bool {
        countryCodes.contains(code.uppercased())
    }

    private func resolvedCountryCode(stored: String?, location: String?) -> String? {
        if let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored.uppercased()
        }
        return EBirdLifeListCSVParser.countryCode(fromLocation: location)
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

    static func countryDisplayName(code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
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
/// **User photos** live beside that JSON under `Birdlists/life-list-photos/` in both
/// the iCloud ubiquity Documents folder and the local Birdlists mirror, so attached
/// JPEGs sync across iPhone / iPad / Mac when the same iCloud account is signed in.
/// Large photos may take longer to appear on other devices until ubiquity finishes
/// downloading; until then the list still opens from the local mirror. Legacy files
/// under `Documents/life-list-photos/` are migrated into Birdlists on load.
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

    /// Local Birdlists photo folder (offline mirror).
    var localPhotoDirectory: URL {
        localBirdlistsDirectory.appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
    }

    /// Legacy pre-Birdlists photo folder (`Documents/life-list-photos/`).
    var legacyPhotoDirectory: URL {
        documentsDirectory.appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
    }

    /// Active photo write target: iCloud Birdlists when available, else local mirror.
    var photoDirectory: URL {
        activePhotoDirectory
    }

    private var localStoreURL: URL {
        localBirdlistsDirectory.appendingPathComponent(Self.storeFileName)
    }

    var activeBirdlistsDirectory: URL {
        iCloudBirdlistsDirectory() ?? localBirdlistsDirectory
    }

    var activePhotoDirectory: URL {
        activeBirdlistsDirectory.appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
    }

    /// Resolves a relative `life-list-photos/…` path for display (iCloud → local → legacy).
    static func resolvedPhotoFileURL(forRelativePath relativePath: String) -> URL? {
        guard relativePath.hasPrefix(photoPathPrefix) else { return nil }
        let file = String(relativePath.dropFirst(photoPathPrefix.count))
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localBirdlists = documents
            .appendingPathComponent(ImportedLocationStore.birdlistsFolderName, isDirectory: true)
            .appendingPathComponent(photoDirectoryName, isDirectory: true)
            .appendingPathComponent(file)
        let legacy = documents
            .appendingPathComponent(photoDirectoryName, isDirectory: true)
            .appendingPathComponent(file)

        var candidates: [URL] = []
        if let iCloudRoot = fm.url(
            forUbiquityContainerIdentifier: ImportedLocationStore.ubiquityContainerIdentifier
        ) {
            let iCloudPhoto = iCloudRoot
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(ImportedLocationStore.birdlistsFolderName, isDirectory: true)
                .appendingPathComponent(photoDirectoryName, isDirectory: true)
                .appendingPathComponent(file)
            candidates.append(iCloudPhoto)
        }
        candidates.append(localBirdlists)
        candidates.append(legacy)

        for url in candidates {
            ensureLocalUbiquitousCopyIfNeededStatic(at: url)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func ensureLocalUbiquitousCopyIfNeededStatic(at url: URL) {
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
            // Fall through to existence check.
        }
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
            var lastCountry = row.lastRecordedCountryCode
            // Classic life-list CSV only has first-seen Date/Location. Keep a prior
            // last-recorded pair from an earlier My Data (or Last*) import.
            if lastDate == nil && lastLocation == nil, let previous {
                lastDate = previous.lastRecordedDate
                lastLocation = previous.lastRecordedLocation
                lastLocId = previous.lastLocId
                lastSubId = previous.lastSubId
                lastCountry = previous.lastRecordedCountryCode
                    ?? EBirdLifeListCSVParser.countryCode(fromLocation: previous.lastRecordedLocation)
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
                firstRecordedCountryCode: row.firstRecordedCountryCode
                    ?? EBirdLifeListCSVParser.countryCode(fromLocation: row.firstRecordedLocation),
                lastRecordedDate: lastDate,
                lastRecordedLocation: lastLocation,
                lastLocId: lastLocId,
                lastSubId: lastSubId,
                lastRecordedCountryCode: lastCountry
                    ?? EBirdLifeListCSVParser.countryCode(fromLocation: lastLocation),
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

    /// Saves a JPEG from the Photos library against a life-list entry.
    /// Writes into Birdlists/life-list-photos (iCloud when available + local mirror).
    @discardableResult
    func setPhoto(jpegData: Data, for entryID: String) throws -> LifeListEntry {
        guard let index = document.entries.firstIndex(where: { $0.id == entryID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        ensurePhotoDirectories()
        let previous = document.entries[index].localPhotoPath
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let filename = "\(entryID)-\(token).jpg"
        try writePhotoData(jpegData, filename: filename)
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
        ensurePhotoDirectories()
    }

    private func ensurePhotoDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: localPhotoDirectory, withIntermediateDirectories: true)
        if let iCloud = iCloudBirdlistsDirectory() {
            let iCloudPhotos = iCloud.appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
            try? fm.createDirectory(at: iCloudPhotos, withIntermediateDirectories: true)
        }
    }

    private func load() -> LifeListDocument? {
        ensureDirectories()
        migrateLegacyPhotosIfNeeded()
        promoteLocalMirrorToICloudIfNeeded()
        promoteLocalPhotosToICloudIfNeeded()
        usesICloudDocuments = iCloudBirdlistsDirectory() != nil
        return readStore(preferringICloud: true)
    }

    private func writePhotoData(_ data: Data, filename: String) throws {
        let localURL = localPhotoDirectory.appendingPathComponent(filename)
        try writeCoordinated(data: data, to: localURL)
        if let iCloud = iCloudBirdlistsDirectory() {
            let iCloudURL = iCloud
                .appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
                .appendingPathComponent(filename)
            try writeCoordinated(data: data, to: iCloudURL)
        }
    }

    /// Copies legacy `Documents/life-list-photos/` files into Birdlists (local + iCloud).
    private func migrateLegacyPhotosIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyPhotoDirectory.path) else { return }
        ensurePhotoDirectories()
        guard let files = try? fm.contentsOfDirectory(
            at: legacyPhotoDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in files where fileURL.pathExtension.lowercased() == "jpg"
            || fileURL.pathExtension.lowercased() == "jpeg"
        {
            let name = fileURL.lastPathComponent
            let localDest = localPhotoDirectory.appendingPathComponent(name)
            if !fm.fileExists(atPath: localDest.path) {
                try? fm.copyItem(at: fileURL, to: localDest)
            }
            if let iCloud = iCloudBirdlistsDirectory() {
                let cloudDest = iCloud
                    .appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
                    .appendingPathComponent(name)
                if !fm.fileExists(atPath: cloudDest.path), let data = try? Data(contentsOf: fileURL) {
                    try? writeCoordinated(data: data, to: cloudDest)
                }
            }
        }
    }

    /// When iCloud becomes available, push local Birdlists photos that are missing in the cloud.
    private func promoteLocalPhotosToICloudIfNeeded() {
        guard let iCloud = iCloudBirdlistsDirectory() else { return }
        let fm = FileManager.default
        let cloudPhotos = iCloud.appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: cloudPhotos, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: localPhotoDirectory.path),
              let files = try? fm.contentsOfDirectory(
                at: localPhotoDirectory,
                includingPropertiesForKeys: nil
              ) else { return }

        for fileURL in files where !fileURL.lastPathComponent.hasPrefix(".") {
            let dest = cloudPhotos.appendingPathComponent(fileURL.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            if let data = try? Data(contentsOf: fileURL) {
                try? writeCoordinated(data: data, to: dest)
            }
        }
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
        migrateLegacyPhotosIfNeeded()
        promoteLocalMirrorToICloudIfNeeded()
        promoteLocalPhotosToICloudIfNeeded()
        usesICloudDocuments = iCloudBirdlistsDirectory() != nil
        if let loaded = readStore(preferringICloud: true) {
            document = loaded
        }
        photoRevision += 1
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
        let fm = FileManager.default
        let candidates = [
            localPhotoDirectory.appendingPathComponent(file),
            legacyPhotoDirectory.appendingPathComponent(file),
            iCloudBirdlistsDirectory()?
                .appendingPathComponent(Self.photoDirectoryName, isDirectory: true)
                .appendingPathComponent(file),
        ].compactMap { $0 }
        for url in candidates where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        BundleImages.invalidate(path: path)
    }
}
