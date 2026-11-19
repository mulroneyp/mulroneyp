import CoreLocation
import Foundation

/// A unique life-list sighting place for Map pins (Country / Global filter).
struct LifeListMapPin: Identifiable, Hashable {
    var id: String
    /// Place title shown on the pin callout.
    var title: String
    var countryCode: String?
    var locId: String?
    /// Query used for CLGeocoder when coordinates are not already known.
    var geocodeQuery: String
    /// How many life-list species reference this place (first and/or last).
    var speciesCount: Int

    var subtitle: String {
        speciesCount == 1 ? "1 species" : "\(speciesCount) species"
    }
}

/// Builds and resolves map pins from life-list entries for the current filter.
enum LifeListMapPins {
    /// Unique sighting locations from `entries` (already Country-filtered, or all for Global).
    static func pins(from entries: [LifeListEntry]) -> [LifeListMapPin] {
        var buckets: [String: Accumulator] = [:]

        for entry in entries {
            ingest(
                into: &buckets,
                speciesID: entry.id,
                location: entry.lastRecordedLocation,
                locId: entry.lastLocId,
                countryCode: entry.lastRecordedCountryCode
                    ?? EBirdLifeListCSVParser.countryCode(fromLocation: entry.lastRecordedLocation)
            )
            ingest(
                into: &buckets,
                speciesID: entry.id,
                location: entry.firstRecordedLocation,
                locId: entry.firstLocId,
                countryCode: entry.firstRecordedCountryCode
                    ?? EBirdLifeListCSVParser.countryCode(fromLocation: entry.firstRecordedLocation)
            )
        }

        return buckets.values
            .map { acc in
                LifeListMapPin(
                    id: acc.id,
                    title: acc.title,
                    countryCode: acc.countryCode,
                    locId: acc.locId,
                    geocodeQuery: geocodeQuery(title: acc.title, countryCode: acc.countryCode),
                    speciesCount: acc.speciesIDs.count
                )
            }
            .sorted {
                if $0.speciesCount != $1.speciesCount { return $0.speciesCount > $1.speciesCount }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    /// Prefer imported hotspot coordinates, then a known PlaceMaps placename geocode query.
    static func knownCoordinate(
        for pin: LifeListMapPin,
        imports: [ImportedLocationRecord]
    ) -> CLLocationCoordinate2D? {
        if let locId = pin.locId?.trimmingCharacters(in: .whitespacesAndNewlines), !locId.isEmpty {
            if let match = imports.first(where: {
                ($0.ebirdLocationId ?? "").caseInsensitiveCompare(locId) == .orderedSame
                    && $0.hasCoordinates
            }), let lat = match.latitude, let lng = match.longitude {
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
        }

        let needle = SpeciesCatalog.normalize(pin.title)
        if !needle.isEmpty,
           let match = imports.first(where: {
               $0.hasCoordinates && SpeciesCatalog.normalize($0.name) == needle
           }),
           let lat = match.latitude,
           let lng = match.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        return nil
    }

    /// Place string without a trailing ` · US-TX` style S/P token, for cleaner geocoding.
    static func placeName(from location: String) -> String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: " · ", options: .backwards) else { return trimmed }
        let tail = String(trimmed[range.upperBound...])
        if EBirdLifeListCSVParser.countryCode(fromStateProvince: tail) != nil {
            return String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func geocodeQuery(title: String, countryCode: String?) -> String {
        let place = placeName(from: title)
        if let code = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            let country = LifeListEntry.countryDisplayName(code: code)
            if place.isEmpty { return country }
            if place.localizedCaseInsensitiveContains(country) { return place }
            return "\(place), \(country)"
        }
        return place
    }

    // MARK: - Private

    private struct Accumulator {
        var id: String
        var title: String
        var countryCode: String?
        var locId: String?
        var speciesIDs: Set<String>
    }

    private static func ingest(
        into buckets: inout [String: Accumulator],
        speciesID: String,
        location: String?,
        locId: String?,
        countryCode: String?
    ) {
        let trimmedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocId = locId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLocation = !(trimmedLocation?.isEmpty ?? true)
        let hasLocId = !(trimmedLocId?.isEmpty ?? true)
        guard hasLocation || hasLocId else { return }

        let title = hasLocation ? trimmedLocation! : trimmedLocId!
        // Prefer place-name identity so a shared / fallback LocID does not merge
        // distinct first vs last sites (classic CSV often reuses LocID for Last*).
        let country = (countryCode ?? EBirdLifeListCSVParser.countryCode(fromLocation: title) ?? "")
            .uppercased()
        let id: String
        if hasLocation {
            id = "name:\(SpeciesCatalog.normalize(placeName(from: title)))|\(country)"
        } else {
            id = "loc:\(trimmedLocId!.uppercased())"
        }

        if var existing = buckets[id] {
            existing.speciesIDs.insert(speciesID)
            if existing.title.isEmpty, hasLocation {
                existing.title = title
            }
            if existing.locId == nil, hasLocId {
                existing.locId = trimmedLocId
            }
            if existing.countryCode == nil {
                existing.countryCode = countryCode
                    ?? EBirdLifeListCSVParser.countryCode(fromLocation: title)
            }
            buckets[id] = existing
        } else {
            buckets[id] = Accumulator(
                id: id,
                title: title,
                countryCode: countryCode ?? EBirdLifeListCSVParser.countryCode(fromLocation: title),
                locId: trimmedLocId,
                speciesIDs: [speciesID]
            )
        }
    }
}

/// Serial geocoder with in-memory cache for life-list map pins.
@MainActor
final class LifeListMapPinResolver: ObservableObject {
    @Published private(set) var coordinates: [String: CLLocationCoordinate2D] = [:]
    @Published private(set) var failedIDs: Set<String> = []
    @Published private(set) var isResolving = false
    @Published private(set) var resolvedCount = 0

    private var cache: [String: CLLocationCoordinate2D] = [:]
    private var negativeCache: Set<String> = []
    private var generation = 0

    func resetPublished() {
        coordinates = [:]
        failedIDs = []
        resolvedCount = 0
        isResolving = false
    }

    /// Resolves pins: imported coords first, then serial geocode of the rest.
    func resolve(pins: [LifeListMapPin], imports: [ImportedLocationRecord]) async {
        generation += 1
        let token = generation
        resetPublished()

        var next: [String: CLLocationCoordinate2D] = [:]
        var pending: [LifeListMapPin] = []

        for pin in pins {
            if let known = LifeListMapPins.knownCoordinate(for: pin, imports: imports) {
                next[pin.id] = known
                continue
            }
            let key = cacheKey(for: pin)
            if let cached = cache[key] {
                next[pin.id] = cached
                continue
            }
            if negativeCache.contains(key) {
                failedIDs.insert(pin.id)
                continue
            }
            pending.append(pin)
        }

        coordinates = next
        resolvedCount = next.count
        guard !pending.isEmpty else { return }

        isResolving = true
        defer {
            if token == generation {
                isResolving = false
            }
        }

        // Cap geocode volume so large Global lists stay responsive.
        let toGeocode = Array(pending.prefix(60))
        for pin in toGeocode {
            guard token == generation else { return }
            let key = cacheKey(for: pin)
            if let coordinate = await geocode(pin.geocodeQuery) {
                cache[key] = coordinate
                var updated = coordinates
                updated[pin.id] = coordinate
                coordinates = updated
                resolvedCount = updated.count
            } else {
                negativeCache.insert(key)
                failedIDs.insert(pin.id)
            }
        }

        // Mark the remainder we skipped as failed for this session (still listed in legend).
        if pending.count > toGeocode.count {
            for pin in pending.dropFirst(toGeocode.count) {
                failedIDs.insert(pin.id)
            }
        }
    }

    private func cacheKey(for pin: LifeListMapPin) -> String {
        SpeciesCatalog.normalize(pin.geocodeQuery)
    }

    private func geocode(_ query: String) async -> CLLocationCoordinate2D? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            geocoder.geocodeAddressString(trimmed) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.location?.coordinate)
            }
        }
    }
}
