import Foundation

/// Builds Apple Maps search URLs for the active place.
enum PlaceMaps {
    /// Known eBird hotspot ids → a Maps-friendly place query.
    /// L-codes alone are not useful in Maps; prefer a real placename.
    private static let knownEBirdHotspots: [String: String] = [
        "L436229": "Hotel Bougainvillea, Heredia, Costa Rica",
    ]

    static func searchQuery(for place: ResolvedPlace) -> String? {
        if let imported = place.imported {
            return queryForImported(imported)
        }
        if let district = place.district, district.id != "all" {
            let title = place.coverage.placeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                return "\(district.label), \(place.coverage.country)"
            }
            return "\(district.label), \(title)"
        }
        let title = place.coverage.placeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let name = place.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func appleMapsURL(for place: ResolvedPlace) -> URL? {
        guard let query = searchQuery(for: place)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    static func isEBirdLocationCode(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        let upper = trimmed.uppercased()
        guard upper.first == "L" else { return false }
        return upper.dropFirst().allSatisfy(\.isNumber)
    }

    private static func queryForImported(_ record: ImportedLocationRecord) -> String? {
        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let renamedAwayFromCode = !name.isEmpty
            && !isEBirdLocationCode(name)
            && (record.ebirdLocationId.map { name.caseInsensitiveCompare($0) != .orderedSame } ?? true)

        if renamedAwayFromCode {
            return name
        }
        if let id = record.ebirdLocationId, let known = knownEBirdHotspots[id] {
            return known
        }
        if !name.isEmpty, !isEBirdLocationCode(name) {
            return name
        }
        // Unknown bare L-code: still open Maps with the best string we have
        // (user-renamed titles win above; otherwise fall back to the id).
        if let id = record.ebirdLocationId, !id.isEmpty {
            return knownEBirdHotspots[id] ?? id
        }
        return name.isEmpty ? nil : name
    }
}
