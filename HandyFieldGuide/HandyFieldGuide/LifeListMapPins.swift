import CoreLocation
import Foundation

/// A unique life-list sighting place for Map pins (Country / Global filter).
struct LifeListMapPin: Identifiable, Hashable {
    var id: String
    /// Place name used for geocoding / matching; not shown as a map callout.
    var title: String
    var countryCode: String?
    /// eBird S/P token when present (`US-TX`, `CR-P`) for region hotspot lookups.
    var regionCode: String?
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
                    regionCode: acc.regionCode,
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

    /// eBird S/P token from a composed location (`Place · US-TX`), when present.
    static func regionCode(from location: String?) -> String? {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty else { return nil }
        let segments = location.components(separatedBy: " · ")
        for segment in segments.reversed() {
            let token = segment.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard EBirdLifeListCSVParser.countryCode(fromStateProvince: token) != nil else { continue }
            // Prefer full `US-TX` when present; bare `US` still works for country hotspots.
            return token
        }
        return nil
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
        var regionCode: String?
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

        let region = regionCode(from: title)

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
            if existing.regionCode == nil {
                existing.regionCode = region
            }
            buckets[id] = existing
        } else {
            buckets[id] = Accumulator(
                id: id,
                title: title,
                countryCode: countryCode ?? EBirdLifeListCSVParser.countryCode(fromLocation: title),
                regionCode: region,
                locId: trimmedLocId,
                speciesIDs: [speciesID]
            )
        }
    }
}

// MARK: - Coordinate cache

/// Disk-backed lat/lng cache so large life lists do not re-resolve every open.
struct LifeListMapCoordinateCache {
    private struct Entry: Codable {
        var latitude: Double
        var longitude: Double
    }

    private var entries: [String: Entry]
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HandyFieldGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("life-list-map-coords.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func coordinate(forKey key: String) -> CLLocationCoordinate2D? {
        guard let entry = entries[key] else { return nil }
        return CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude)
    }

    mutating func store(_ coordinate: CLLocationCoordinate2D, forKey key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries[trimmed] = Entry(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Resolver

/// Resolves life-list map pins: imports → disk/memory cache → eBird hotspots → geocode.
/// Geocodes every remaining unique place (no artificial skip cap); only true lookup
/// failures stay unpin-able, and those are reported in the map banner.
@MainActor
final class LifeListMapPinResolver: ObservableObject {
    @Published private(set) var coordinates: [String: CLLocationCoordinate2D] = [:]
    @Published private(set) var failedIDs: Set<String> = []
    @Published private(set) var isResolving = false
    @Published private(set) var resolvedCount = 0

    private var memoryCache: [String: CLLocationCoordinate2D] = [:]
    private var negativeCache: Set<String> = []
    private var diskCache = LifeListMapCoordinateCache()
    private var generation = 0
    /// Region hotspots fetched this session (avoid re-downloading the same S/P).
    private var regionHotspotIndex: [String: [String: CLLocationCoordinate2D]] = [:]
    private var regionNameIndex: [String: [String: CLLocationCoordinate2D]] = [:]

    func resetPublished() {
        coordinates = [:]
        failedIDs = []
        resolvedCount = 0
        isResolving = false
    }

    /// Resolves pins: imported coords, cache, eBird hotspot match, then geocode the rest.
    func resolve(pins: [LifeListMapPin], imports: [ImportedLocationRecord]) async {
        generation += 1
        let token = generation
        resetPublished()

        var next: [String: CLLocationCoordinate2D] = [:]
        var pending: [LifeListMapPin] = []
        var dirtyCache = false

        for pin in pins {
            if let known = LifeListMapPins.knownCoordinate(for: pin, imports: imports) {
                next[pin.id] = known
                remember(known, for: pin, dirty: &dirtyCache)
                continue
            }
            if let cached = cachedCoordinate(for: pin) {
                next[pin.id] = cached
                continue
            }
            if isNegativelyCached(pin) {
                failedIDs.insert(pin.id)
                continue
            }
            pending.append(pin)
        }

        coordinates = next
        resolvedCount = next.count

        guard !pending.isEmpty else {
            if dirtyCache { diskCache.save() }
            return
        }

        isResolving = true
        defer {
            if token == generation {
                isResolving = false
            }
            if dirtyCache { diskCache.save() }
        }

        // Prefer eBird hotspot coordinates (batch by region, then per-locId) when a key exists.
        if let apiKey = EBirdAPIKeyStore.load() {
            pending = await resolveViaHotspots(
                pending: pending,
                apiKey: apiKey,
                token: token,
                next: &next,
                dirtyCache: &dirtyCache
            )
            guard token == generation else { return }
        }

        // Geocode every remaining unique place — no volume cap. CLGeocoder is serial.
        for pin in pending {
            guard token == generation else { return }
            if let coordinate = await geocode(pin.geocodeQuery) {
                remember(coordinate, for: pin, dirty: &dirtyCache)
                var updated = coordinates
                updated[pin.id] = coordinate
                coordinates = updated
                resolvedCount = updated.count
            } else {
                markNegative(pin)
                failedIDs.insert(pin.id)
            }
        }
    }

    // MARK: - Hotspot matching

    private func resolveViaHotspots(
        pending: [LifeListMapPin],
        apiKey: String,
        token: Int,
        next: inout [String: CLLocationCoordinate2D],
        dirtyCache: inout Bool
    ) async -> [LifeListMapPin] {
        var remaining = pending

        // Batch-download hotspots for subnational S/P codes (`US-TX`, `CR-P`) only.
        // Bare country codes (especially `US`) can be huge; those pins use per-LocID info below.
        let regionKeys = Set(remaining.compactMap { hotspotRegionKey(for: $0) })
            .filter { $0.contains("-") }
        for region in regionKeys.sorted() {
            guard token == generation else { return remaining }
            await ensureRegionHotspots(regionCode: region, apiKey: apiKey)
        }

        var stillPending: [LifeListMapPin] = []
        for pin in remaining {
            if let coordinate = hotspotCoordinate(for: pin) {
                remember(coordinate, for: pin, dirty: &dirtyCache)
                next[pin.id] = coordinate
                var updated = coordinates
                updated[pin.id] = coordinate
                coordinates = updated
                resolvedCount = updated.count
            } else {
                stillPending.append(pin)
            }
        }
        remaining = stillPending

        // Individual hotspot info for leftover L-codes (private sites 404 → geocode later).
        // Deduplicate LocIDs and fetch a few at a time.
        var locIdPins: [String: [LifeListMapPin]] = [:]
        var withoutLocId: [LifeListMapPin] = []
        for pin in remaining {
            let locId = pin.locId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !locId.isEmpty, PlaceMaps.isEBirdLocationCode(locId) {
                locIdPins[locId.uppercased(), default: []].append(pin)
            } else {
                withoutLocId.append(pin)
            }
        }

        stillPending = withoutLocId
        let uniqueLocIds = locIdPins.keys.sorted()
        var locIdCursor = uniqueLocIds.startIndex
        while locIdCursor < uniqueLocIds.endIndex {
            guard token == generation else { return remaining }
            let end = uniqueLocIds.index(locIdCursor, offsetBy: 6, limitedBy: uniqueLocIds.endIndex)
                ?? uniqueLocIds.endIndex
            let batch = Array(uniqueLocIds[locIdCursor..<end])
            locIdCursor = end

            var batchCoords: [String: (CLLocationCoordinate2D, String)] = [:]
            await withTaskGroup(of: (String, CLLocationCoordinate2D, String)?.self) { group in
                for locId in batch {
                    group.addTask {
                        do {
                            let info = try await EBirdAPIClient.shared.hotspotInfo(
                                locId: locId,
                                apiKey: apiKey
                            )
                            guard let lat = info.lat, let lng = info.lng else { return nil }
                            return (
                                locId,
                                CLLocationCoordinate2D(latitude: lat, longitude: lng),
                                info.locName
                            )
                        } catch {
                            return nil
                        }
                    }
                }
                for await item in group {
                    guard let item else { continue }
                    batchCoords[item.0] = (item.1, item.2)
                }
            }

            for locId in batch {
                guard let pinsForLoc = locIdPins[locId] else { continue }
                if let matched = batchCoords[locId] {
                    let coordinate = matched.0
                    let locName = matched.1
                    for pin in pinsForLoc {
                        remember(coordinate, for: pin, dirty: &dirtyCache)
                        if let region = hotspotRegionKey(for: pin) {
                            regionHotspotIndex[region, default: [:]][locId] = coordinate
                            let nameKey = SpeciesCatalog.normalize(locName)
                            if !nameKey.isEmpty {
                                regionNameIndex[region, default: [:]][nameKey] = coordinate
                            }
                        }
                        next[pin.id] = coordinate
                        var updated = coordinates
                        updated[pin.id] = coordinate
                        coordinates = updated
                        resolvedCount = updated.count
                    }
                } else {
                    stillPending.append(contentsOf: pinsForLoc)
                }
            }
        }
        return stillPending
    }

    private func hotspotRegionKey(for pin: LifeListMapPin) -> String? {
        if let region = pin.regionCode?.trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty {
            return region.uppercased()
        }
        if let country = pin.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
            return country.uppercased()
        }
        return nil
    }

    private func ensureRegionHotspots(regionCode: String, apiKey: String) async {
        let key = regionCode.uppercased()
        if regionHotspotIndex[key] != nil { return }
        do {
            let hotspots = try await EBirdAPIClient.shared.hotspots(inRegion: key, apiKey: apiKey)
            var byId: [String: CLLocationCoordinate2D] = [:]
            var byName: [String: CLLocationCoordinate2D] = [:]
            for hotspot in hotspots {
                guard let lat = hotspot.lat, let lng = hotspot.lng else { continue }
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                let locId = hotspot.locId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if !locId.isEmpty {
                    byId[locId] = coordinate
                }
                let nameKey = SpeciesCatalog.normalize(hotspot.locName)
                if !nameKey.isEmpty, byName[nameKey] == nil {
                    byName[nameKey] = coordinate
                }
            }
            regionHotspotIndex[key] = byId
            regionNameIndex[key] = byName
        } catch {
            regionHotspotIndex[key] = [:]
            regionNameIndex[key] = [:]
        }
    }

    private func hotspotCoordinate(for pin: LifeListMapPin) -> CLLocationCoordinate2D? {
        guard let region = hotspotRegionKey(for: pin) else { return nil }
        if let locId = pin.locId?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !locId.isEmpty,
           let coordinate = regionHotspotIndex[region]?[locId] {
            return coordinate
        }
        let nameKey = SpeciesCatalog.normalize(LifeListMapPins.placeName(from: pin.title))
        if !nameKey.isEmpty, let coordinate = regionNameIndex[region]?[nameKey] {
            return coordinate
        }
        return nil
    }

    // MARK: - Cache helpers

    private func cacheKeys(for pin: LifeListMapPin) -> [String] {
        var keys: [String] = []
        if let locId = pin.locId?.trimmingCharacters(in: .whitespacesAndNewlines), !locId.isEmpty {
            keys.append("loc:\(locId.uppercased())")
        }
        let geo = SpeciesCatalog.normalize(pin.geocodeQuery)
        if !geo.isEmpty {
            keys.append("geo:\(geo)")
        }
        return keys
    }

    private func cachedCoordinate(for pin: LifeListMapPin) -> CLLocationCoordinate2D? {
        for key in cacheKeys(for: pin) {
            if let memory = memoryCache[key] { return memory }
            if let disk = diskCache.coordinate(forKey: key) {
                memoryCache[key] = disk
                return disk
            }
        }
        return nil
    }

    private func isNegativelyCached(_ pin: LifeListMapPin) -> Bool {
        cacheKeys(for: pin).contains { negativeCache.contains($0) }
    }

    private func markNegative(_ pin: LifeListMapPin) {
        for key in cacheKeys(for: pin) {
            negativeCache.insert(key)
        }
    }

    private func remember(
        _ coordinate: CLLocationCoordinate2D,
        for pin: LifeListMapPin,
        dirty: inout Bool
    ) {
        for key in cacheKeys(for: pin) {
            memoryCache[key] = coordinate
            diskCache.store(coordinate, forKey: key)
            dirty = true
        }
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
