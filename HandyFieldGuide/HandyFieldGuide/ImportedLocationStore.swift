import Foundation

struct ImportedLocationRecord: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var ebirdLocationId: String?
    var sourceFileName: String
    var importedAt: Date
    var reportedTaxonCount: Int?
    var species: [ImportedTaxonRecord]

    var placeTitle: String {
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

@MainActor
final class ImportedLocationStore: ObservableObject {
    @Published private(set) var locations: [ImportedLocationRecord] = []

    private let fileName = "imported-locations.json"
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

    init() {
        locations = load()
    }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var storeURL: URL {
        documentsDirectory.appendingPathComponent(fileName)
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
    func upsert(from parsed: ParsedBarchart, displayName: String?) -> ImportedLocationRecord {
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
            }
        )
        if let index = locations.firstIndex(where: { $0.id == record.id || ($0.ebirdLocationId != nil && $0.ebirdLocationId == record.ebirdLocationId) }) {
            locations[index] = record
        } else {
            locations.append(record)
        }
        persist()
        return record
    }

    /// Updates the display name for a saved import and writes `imported-locations.json`.
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
        // Offer the bundled sample in Documents for re-import via the Files app.
        copyBundledFixtureIntoDocumentsIfNeeded()
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: storeURL)
            return try decoder.decode([ImportedLocationRecord].self, from: data)
        } catch {
            return []
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(locations)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            // Persistence failures leave the in-memory list intact for the session.
        }
    }

    /// Copies the bundled L436229 fixture into Documents so it appears under Files → On My iPhone → Handy Field Guide.
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
