import CoreLocation
import Foundation

/// Thin client for eBird API 2.0 (hotspots / regions) plus checklist frequency.
///
/// **Authenticated (`X-eBirdApiToken` on `api.ebird.org` only):**
/// - `GET https://api.ebird.org/v2/ref/hotspot/{regionCode}?fmt=json`
/// - `GET https://api.ebird.org/v2/ref/hotspot/geo?lat=&lng=&dist=&fmt=json`
/// - `GET https://api.ebird.org/v2/ref/hotspot/info/{locId}`
/// - `GET https://api.ebird.org/v2/ref/region/list/{type}/{parent}`
/// - `GET https://api.ebird.org/v2/product/spplist/{locId}`
/// - `GET https://api.ebird.org/v2/data/obs/{locId}/historic/{y}/{m}/{d}`
/// - `GET https://api.ebird.org/v2/ref/taxonomy/ebird?species=`
///
/// **Not used:** `ref/region/find` — it returns HTTP 403 even with a valid personal
/// key, which previously made the app misreport “eBird rejected the API key”.
///
/// **Frequency:** prefer website histogram `ebird.org/barchartData` (no API key —
/// that host is not the API and ignores/does not accept the token). If eBird
/// returns a login / bot wall, fall back to species list + monthly historic
/// samples from the official API.
actor EBirdAPIClient {
    static let shared = EBirdAPIClient()

    private let session: URLSession
    /// Histogram downloads must not follow CAS login redirects into an HTML page.
    private let barchartSession: URLSession
    private let apiBase = URL(string: "https://api.ebird.org/v2")!
    private let barchartBase = URL(string: "https://ebird.org/barchartData")!
    private let redirectBlocker = RedirectBlockingDelegate()
    private static let clientUserAgent = "HandyFieldGuide/1.0 (iOS; birding field guide; +https://github.com/mulroneyp/mulroneyp)"

    init(session: URLSession = .shared) {
        self.session = session
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpAdditionalHeaders = [
            "Accept": "text/tab-separated-values, application/json, text/plain, */*",
            "User-Agent": Self.clientUserAgent,
        ]
        self.barchartSession = URLSession(
            configuration: config,
            delegate: redirectBlocker,
            delegateQueue: nil
        )
    }

    // MARK: - Key check

    /// Cheap authenticated call used to distinguish a bad key from other 403s.
    func validateAPIKey(_ apiKey: String) async throws {
        let key = EBirdAPIKeyStore.sanitize(apiKey)
        guard !key.isEmpty else { throw EBirdAPIError.missingAPIKey }
        // Hotspot info requires a key and succeeds for any valid personal token.
        _ = try await hotspotInfo(locId: "L436229", apiKey: key)
    }

    // MARK: - Hotspot / region search

    func searchHotspots(query raw: String, apiKey: String) async throws -> [EBirdHotspot] {
        let key = EBirdAPIKeyStore.sanitize(apiKey)
        guard !key.isEmpty else { throw EBirdAPIError.missingAPIKey }

        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        if let locId = Self.locationId(from: query) {
            let info = try await hotspotInfo(locId: locId, apiKey: key)
            return [info]
        }

        var byId: [String: EBirdHotspot] = [:]

        if let regionCode = Self.regionCode(from: query) {
            for hotspot in try await hotspots(inRegion: regionCode, apiKey: key) {
                byId[hotspot.locId] = hotspot
            }
            return sortedHotspots(byId.values)
        }

        // Place-name path: geocode → nearby hotspots (does not use region/find).
        if let coordinate = await geocode(query) {
            let nearby = try await nearbyHotspots(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                distanceKm: 50,
                excluding: nil,
                apiKey: key
            )
            for hotspot in nearby {
                if Self.nameMatches(hotspot.locName, query: query) || nearby.count <= 25 {
                    byId[hotspot.locId] = hotspot
                }
            }
            // Prefer name matches when we have many nearby results.
            let named = byId.values.filter { Self.nameMatches($0.locName, query: query) }
            if !named.isEmpty {
                return sortedHotspots(named)
            }
            if !byId.isEmpty {
                return sortedHotspots(byId.values)
            }
        }

        // Region-list fallback: match country / subnational names, then filter hotspots.
        for region in try await matchingRegions(query: query, apiKey: key).prefix(6) {
            let hotspots = try await hotspots(inRegion: region.code, apiKey: key)
            for hotspot in hotspots where Self.nameMatches(hotspot.locName, query: query)
                || Self.isTightRegionMatch(region, query: query) {
                byId[hotspot.locId] = hotspot
            }
            if byId.count >= 40 { break }
        }

        if byId.isEmpty {
            // Last resort: if the query matches a country name tightly, show top hotspots there.
            if let country = try await matchingCountries(query: query, apiKey: key).first,
               Self.isTightRegionMatch(country, query: query) {
                let hotspots = try await hotspots(inRegion: country.code, apiKey: key)
                return sortedHotspots(hotspots.prefix(40))
            }
        }

        return sortedHotspots(byId.values)
    }

    func nearbyHotspots(
        latitude: Double,
        longitude: Double,
        distanceKm: Double = 10,
        excluding locId: String?,
        apiKey: String
    ) async throws -> [EBirdHotspot] {
        let key = EBirdAPIKeyStore.sanitize(apiKey)
        var components = URLComponents(
            url: apiBase.appendingPathComponent("ref/hotspot/geo"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude)),
            URLQueryItem(name: "dist", value: String(min(max(distanceKm, 0), 50))),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        let hotspots: [EBirdHotspot] = try await getJSON(url: components.url!, apiKey: key)
        return hotspots
            .filter { $0.locId != locId }
            .sorted {
                ($0.numSpeciesAllTime ?? 0) > ($1.numSpeciesAllTime ?? 0)
            }
    }

    func hotspotInfo(locId: String, apiKey: String) async throws -> EBirdHotspot {
        let url = apiBase
            .appendingPathComponent("ref/hotspot/info")
            .appendingPathComponent(locId)
        return try await getJSON(url: url, apiKey: EBirdAPIKeyStore.sanitize(apiKey))
    }

    // MARK: - Frequency / barchart

    /// Downloads checklist frequency for a hotspot (48 week columns = 4×12 months).
    func fetchFrequencyBarchart(
        locId: String,
        apiKey: String,
        beginYear: Int? = nil,
        endYear: Int? = nil
    ) async throws -> ParsedBarchart {
        let key = EBirdAPIKeyStore.sanitize(apiKey)
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: Date())
        let eyr = endYear ?? currentYear
        let byr = beginYear ?? max(2006, eyr - 5)
        let sourceFileName = "ebird_\(locId)__\(byr)_\(eyr)_1_12_barchart.txt"

        // Prefer website histogram (same shape as Files `.txt`). Do **not** send the
        // API token — `ebird.org` is not `api.ebird.org` and a 403/login there is not
        // a rejected key.
        do {
            let data = try await fetchBarchartData(
                locId: locId,
                beginYear: byr,
                endYear: eyr,
                format: "tsv"
            )
            var parsed = try EBirdBarchartParser.parse(data: data, sourceFileName: sourceFileName)
            if parsed.ebirdLocationId == nil {
                parsed.ebirdLocationId = locId
            }
            return parsed
        } catch let error as EBirdAPIError {
            switch error {
            case .loginRequired, .httpStatus, .invalidResponse, .decodeFailed, .network:
                break // fall through
            default:
                throw error
            }
        } catch {
            // Fall through to JSON / API product fallback.
        }

        do {
            let data = try await fetchBarchartData(
                locId: locId,
                beginYear: byr,
                endYear: eyr,
                format: "json"
            )
            return try EBirdBarchartJSONParser.parse(
                data: data,
                locId: locId,
                sourceFileName: sourceFileName
            )
        } catch let error as EBirdAPIError {
            switch error {
            case .loginRequired, .httpStatus, .invalidResponse, .decodeFailed, .network:
                break
            default:
                throw error
            }
        } catch {
            // Fall through.
        }

        return try await fetchFrequencyFromAPIProducts(
            locId: locId,
            apiKey: key,
            endYear: eyr,
            sourceFileName: sourceFileName
        )
    }

    // MARK: - Internals

    private func matchingRegions(query: String, apiKey: String) async throws -> [EBirdRegion] {
        var matches: [EBirdRegion] = []
        let countries = try await matchingCountries(query: query, apiKey: apiKey)
        matches.append(contentsOf: countries)

        for country in countries.prefix(4) {
            let subs: [EBirdRegion] = try await regionList(
                type: "subnational1",
                parent: country.code,
                apiKey: apiKey
            )
            let ranked = Self.rankRegions(subs, query: query).filter {
                Self.nameMatches($0.name, query: query) || Self.isTightRegionMatch($0, query: query)
            }
            matches.append(contentsOf: ranked.prefix(6))
        }

        // Also try matching subnational names when the query didn't match a country
        // (e.g. "Alajuela") by scanning a few likely parents from tokenized country hits
        // already handled above; if still empty, scan all countries is too heavy — skip.
        return Self.rankRegions(matches, query: query)
    }

    private func matchingCountries(query: String, apiKey: String) async throws -> [EBirdRegion] {
        let countries: [EBirdRegion] = try await regionList(
            type: "country",
            parent: "world",
            apiKey: apiKey
        )
        return Self.rankRegions(countries, query: query).filter {
            Self.nameMatches($0.name, query: query) || Self.isTightRegionMatch($0, query: query)
        }
    }

    private func regionList(type: String, parent: String, apiKey: String) async throws -> [EBirdRegion] {
        let url = apiBase
            .appendingPathComponent("ref/region/list")
            .appendingPathComponent(type)
            .appendingPathComponent(parent)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fmt", value: "json")]
        return try await getJSON(url: components.url!, apiKey: apiKey)
    }

    private func hotspots(inRegion regionCode: String, apiKey: String) async throws -> [EBirdHotspot] {
        var components = URLComponents(
            url: apiBase
                .appendingPathComponent("ref/hotspot")
                .appendingPathComponent(regionCode),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "fmt", value: "json")]
        return try await getJSON(url: components.url!, apiKey: apiKey)
    }

    /// Website histogram only — never attach `X-eBirdApiToken`.
    private func fetchBarchartData(
        locId: String,
        beginYear: Int,
        endYear: Int,
        format: String
    ) async throws -> Data {
        var components = URLComponents(url: barchartBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "r", value: locId),
            URLQueryItem(name: "bmo", value: "1"),
            URLQueryItem(name: "emo", value: "12"),
            URLQueryItem(name: "byr", value: String(beginYear)),
            URLQueryItem(name: "eyr", value: String(endYear)),
            URLQueryItem(name: "fmt", value: format),
        ]
        guard let url = components.url else { throw EBirdAPIError.badURL }
        var request = URLRequest(url: url)
        request.setValue(Self.clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await barchartSession.data(for: request)
        } catch let error as URLError {
            throw EBirdAPIError.network(error)
        } catch {
            throw EBirdAPIError.network(nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw EBirdAPIError.invalidResponse
        }
        if (300..<400).contains(http.statusCode) {
            throw EBirdAPIError.loginRequired
        }
        // Website 403s are login/WAF walls — not API key rejection.
        if http.statusCode == 401 || http.statusCode == 403 {
            throw EBirdAPIError.loginRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EBirdAPIError.httpStatus(http.statusCode, host: .website)
        }
        if Self.looksLikeHTMLLogin(data) {
            throw EBirdAPIError.loginRequired
        }
        return data
    }

    /// Approximate 48-week frequencies from species list + one mid-month historic
    /// sample per calendar month for the latest complete-ish year.
    private func fetchFrequencyFromAPIProducts(
        locId: String,
        apiKey: String,
        endYear: Int,
        sourceFileName: String
    ) async throws -> ParsedBarchart {
        let listURL = apiBase
            .appendingPathComponent("product/spplist")
            .appendingPathComponent(locId)
        let codes: [String] = try await getJSON(url: listURL, apiKey: apiKey)
        guard !codes.isEmpty else { throw EBirdAPIError.emptyFrequency }

        let sampleYear = max(2006, endYear - 1)
        var monthHits: [String: [Int]] = [:]
        monthHits.reserveCapacity(codes.count)
        for code in codes {
            monthHits[code] = Array(repeating: 0, count: 12)
        }

        for month in 1...12 {
            let url = apiBase
                .appendingPathComponent("data/obs")
                .appendingPathComponent(locId)
                .appendingPathComponent("historic")
                .appendingPathComponent(String(sampleYear))
                .appendingPathComponent(String(month))
                .appendingPathComponent("15")
            let observations: [EBirdObservation]
            do {
                observations = try await getJSON(url: url, apiKey: apiKey)
            } catch let error as EBirdAPIError {
                switch error {
                case .unauthorized, .missingAPIKey, .network:
                    throw error
                default:
                    // Missing days / sparse coverage — keep zeros for that month.
                    continue
                }
            }
            var seen = Set<String>()
            for obs in observations {
                let code = obs.speciesCode
                guard !code.isEmpty, seen.insert(code).inserted else { continue }
                if monthHits[code] == nil {
                    monthHits[code] = Array(repeating: 0, count: 12)
                }
                monthHits[code]?[month - 1] = 1
            }
        }

        let allCodes = Array(Set(codes).union(monthHits.keys))
        let names = try await commonNames(forSpeciesCodes: allCodes, apiKey: apiKey)

        var rows: [ParsedBarchartSpecies] = []
        rows.reserveCapacity(allCodes.count)
        for code in allCodes {
            let name = names[code] ?? code
            let hits = monthHits[code] ?? Array(repeating: 0, count: 12)
            // Present months → ~25% reporting rate; absent → scarce threshold so they
            // remain importable but hidden by the default scarce filter.
            var weeks: [Double] = []
            weeks.reserveCapacity(48)
            var means: [Double] = []
            var maxes: [Double] = []
            for month in 0..<12 {
                let rate = hits[month] > 0 ? 0.25 : EBirdBarchartParser.nearZeroThreshold
                means.append(rate)
                maxes.append(rate)
                weeks.append(contentsOf: Array(repeating: rate, count: 4))
            }
            rows.append(
                ParsedBarchartSpecies(
                    commonName: name,
                    kind: EBirdBarchartParser.classify(name),
                    monthlyMean: means,
                    monthlyMax: maxes,
                    weekFrequencies: weeks
                )
            )
        }

        rows.sort {
            $0.commonName.localizedCaseInsensitiveCompare($1.commonName) == .orderedAscending
        }

        return ParsedBarchart(
            ebirdLocationId: locId,
            sourceFileName: sourceFileName,
            reportedTaxonCount: rows.count,
            species: rows
        )
    }

    private func commonNames(forSpeciesCodes codes: [String], apiKey: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(codes.count)
        let batchSize = 40
        var index = 0
        while index < codes.count {
            let end = min(index + batchSize, codes.count)
            let batch = Array(codes[index..<end])
            index = end
            var components = URLComponents(
                url: apiBase.appendingPathComponent("ref/taxonomy/ebird"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "species", value: batch.joined(separator: ",")),
            ]
            let taxa: [EBirdTaxon] = try await getJSON(url: components.url!, apiKey: apiKey)
            for taxon in taxa {
                if !taxon.speciesCode.isEmpty, !taxon.comName.isEmpty {
                    result[taxon.speciesCode] = taxon.comName
                }
            }
        }
        return result
    }

    private func getJSON<T: Decodable>(url: URL, apiKey: String) async throws -> T {
        let key = EBirdAPIKeyStore.sanitize(apiKey)
        guard !key.isEmpty else { throw EBirdAPIError.missingAPIKey }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-eBirdApiToken")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 45
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw EBirdAPIError.invalidResponse
            }
            switch http.statusCode {
            case 200..<300:
                do {
                    return try JSONDecoder().decode(T.self, from: data)
                } catch {
                    throw EBirdAPIError.decodeFailed
                }
            case 401:
                throw EBirdAPIError.unauthorized
            case 403:
                // Empty-body 403 is eBird's usual "bad/missing token" shape — but some
                // documented endpoints (notably ref/region/find) 403 even with a valid
                // key. Callers that need a firm answer should use validateAPIKey(_:).
                if data.isEmpty {
                    throw EBirdAPIError.unauthorized
                }
                throw EBirdAPIError.httpStatus(403, host: .api)
            case 404:
                throw EBirdAPIError.notFound
            default:
                throw EBirdAPIError.httpStatus(http.statusCode, host: .api)
            }
        } catch let error as EBirdAPIError {
            throw error
        } catch let error as URLError {
            throw EBirdAPIError.network(error)
        } catch {
            throw EBirdAPIError.network(nil)
        }
    }

    private func geocode(_ query: String) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            geocoder.geocodeAddressString(query) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.location?.coordinate)
            }
        }
    }

    private func sortedHotspots<S: Sequence>(_ hotspots: S) -> [EBirdHotspot] where S.Element == EBirdHotspot {
        hotspots.sorted {
            let left = $0.numSpeciesAllTime ?? 0
            let right = $1.numSpeciesAllTime ?? 0
            if left != right { return left > right }
            return $0.locName.localizedCaseInsensitiveCompare($1.locName) == .orderedAscending
        }
    }

    private static func locationId(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.range(of: #"^L\d{5,}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    /// eBird region codes like `CR`, `US-CA`, `CR-A`, `US-NY-005`.
    private static func regionCode(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.range(of: #"^[A-Z]{2}(-[A-Z0-9]+)*$"#, options: .regularExpression) != nil else {
            return nil
        }
        // Avoid treating short words as country codes when they are clear English.
        let blocked: Set<String> = ["OR", "IN", "ME", "OK", "NO", "TO", "BE", "SO", "AS", "AN"]
        if trimmed.count == 2, blocked.contains(trimmed) { return nil }
        return trimmed
    }

    private static func nameMatches(_ name: String, query: String) -> Bool {
        let hay = LocationResolver.normalize(name)
        let needle = LocationResolver.normalize(query)
        guard !needle.isEmpty else { return true }
        if hay.contains(needle) { return true }
        let tokens = needle.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return hay.contains(needle) }
        let hits = tokens.filter { hay.contains($0) }.count
        return hits * 2 >= tokens.count
    }

    private static func isTightRegionMatch(_ region: EBirdRegion, query: String) -> Bool {
        let hay = LocationResolver.normalize(region.name)
        let needle = LocationResolver.normalize(query)
        return hay == needle || hay.hasPrefix(needle) || needle.hasPrefix(hay)
    }

    private static func rankRegions(_ regions: [EBirdRegion], query: String) -> [EBirdRegion] {
        let needle = LocationResolver.normalize(query)
        return regions.sorted { lhs, rhs in
            let lScore = regionScore(lhs, needle: needle)
            let rScore = regionScore(rhs, needle: needle)
            if lScore != rScore { return lScore > rScore }
            return lhs.name.count < rhs.name.count
        }
    }

    private static func regionScore(_ region: EBirdRegion, needle: String) -> Int {
        let hay = LocationResolver.normalize(region.name)
        var score = 0
        if hay == needle { score += 100 }
        if hay.hasPrefix(needle) { score += 40 }
        if hay.contains(needle) { score += 20 }
        score += region.code.filter { $0 == "-" }.count * 5
        if region.code.uppercased() == needle.uppercased().replacingOccurrences(of: " ", with: "-") {
            score += 80
        }
        return score
    }

    private static func looksLikeHTMLLogin(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(800), encoding: .utf8)?.lowercased() else {
            return false
        }
        if text.contains("<!doctype html") || text.contains("<html") {
            return text.contains("sign in")
                || text.contains("login")
                || text.contains("cassso")
                || text.contains("not a bot")
                || text.contains("notauthorized")
                || text.contains("anubis")
        }
        return false
    }
}

// MARK: - DTOs

struct EBirdRegion: Decodable, Hashable, Identifiable {
    var code: String
    var name: String
    var id: String { code }
}

struct EBirdHotspot: Decodable, Hashable, Identifiable {
    var locId: String
    var locName: String
    var countryCode: String?
    var subnational1Code: String?
    var subnational2Code: String?
    var lat: Double?
    var lng: Double?
    var latestObsDt: String?
    var numSpeciesAllTime: Int?

    var id: String { locId }

    var subtitle: String {
        var parts: [String] = [locId]
        if let numSpeciesAllTime {
            parts.append("\(numSpeciesAllTime) spp.")
        }
        if let subnational1Code {
            parts.append(subnational1Code)
        } else if let countryCode {
            parts.append(countryCode)
        }
        return parts.joined(separator: " · ")
    }

    private enum CodingKeys: String, CodingKey {
        case locId, locName, countryCode, subnational1Code, subnational2Code
        case lat, lng, latitude, longitude, latestObsDt, numSpeciesAllTime
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locId = try container.decodeIfPresent(String.self, forKey: .locId) ?? ""
        if let locName = try container.decodeIfPresent(String.self, forKey: .locName) {
            self.locName = locName
        } else {
            self.locName = try container.decodeIfPresent(String.self, forKey: .name) ?? locId
        }
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        subnational1Code = try container.decodeIfPresent(String.self, forKey: .subnational1Code)
        subnational2Code = try container.decodeIfPresent(String.self, forKey: .subnational2Code)
        lat = try container.decodeIfPresent(Double.self, forKey: .lat)
            ?? container.decodeIfPresent(Double.self, forKey: .latitude)
        lng = try container.decodeIfPresent(Double.self, forKey: .lng)
            ?? container.decodeIfPresent(Double.self, forKey: .longitude)
        latestObsDt = try container.decodeIfPresent(String.self, forKey: .latestObsDt)
        numSpeciesAllTime = try container.decodeIfPresent(Int.self, forKey: .numSpeciesAllTime)
    }
}

private struct EBirdObservation: Decodable {
    var speciesCode: String
    var comName: String?

    private enum CodingKeys: String, CodingKey {
        case speciesCode, comName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speciesCode = try container.decodeIfPresent(String.self, forKey: .speciesCode) ?? ""
        comName = try container.decodeIfPresent(String.self, forKey: .comName)
    }
}

private struct EBirdTaxon: Decodable {
    var speciesCode: String
    var comName: String

    private enum CodingKeys: String, CodingKey {
        case speciesCode, comName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speciesCode = try container.decodeIfPresent(String.self, forKey: .speciesCode) ?? ""
        comName = try container.decodeIfPresent(String.self, forKey: .comName) ?? ""
    }
}

/// Blocks HTTP redirects so CAS login walls surface as 3xx instead of HTML bodies.
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum EBirdAPIError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case notFound
    case loginRequired
    case badURL
    case invalidResponse
    case decodeFailed
    case emptyFrequency
    case httpStatus(Int, host: EBirdHost = .api)
    case network(URLError?)

    enum EBirdHost {
        case api
        case website
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your free eBird API key in Settings first (ebird.org/api/keygen)."
        case .unauthorized:
            return "eBird rejected the API key. Check or replace it in Settings."
        case .notFound:
            return "That eBird hotspot or region was not found."
        case .loginRequired:
            return "eBird’s website blocked the histogram download (sign-in or bot check). The app will try the official API species list instead; if that also fails, import a barchart .txt."
        case .badURL:
            return "Could not build the eBird request URL."
        case .invalidResponse:
            return "Unexpected response from eBird."
        case .decodeFailed:
            return "Could not read eBird’s response."
        case .emptyFrequency:
            return "No frequency rows were returned for that hotspot."
        case .httpStatus(let code, let host):
            switch host {
            case .website:
                return "eBird website request failed (HTTP \(code)). This is not an API-key problem — try again or import a barchart .txt."
            case .api:
                return "eBird API request failed (HTTP \(code))."
            }
        case .network(let error):
            if error?.code == .notConnectedToInternet || error?.code == .networkConnectionLost {
                return "No network connection. Connect and try again, or import a barchart .txt."
            }
            return "Couldn’t reach eBird. Check your connection and try again."
        }
    }
}
