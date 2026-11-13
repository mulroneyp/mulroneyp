import Foundation

/// Thin client for eBird API 2.0 (hotspots / regions) plus the bar-chart
/// histogram download used for checklist frequency by week.
///
/// **Authenticated (API key in `X-eBirdApiToken`):**
/// - `GET https://api.ebird.org/v2/ref/region/find?q=`
/// - `GET https://api.ebird.org/v2/ref/hotspot/{regionCode}?fmt=json`
/// - `GET https://api.ebird.org/v2/ref/hotspot/geo?lat=&lng=&dist=&fmt=json`
/// - `GET https://api.ebird.org/v2/ref/hotspot/info/{locId}`
///
/// **Frequency by period (same shape as a Frequency / barchart `.txt` export):**
/// - `GET https://ebird.org/barchartData?r={locId}&bmo=1&emo=12&byr=&eyr=&fmt=tsv`
/// - JSON twin: same path with `fmt=json` (parsed when TSV is unavailable)
///
/// The histogram URL is what eBird’s Bar Charts “Download Histogram Data” uses.
/// It is not listed in the official Postman API 2.0 collection; the API key is
/// still sent on the request. If eBird returns a login wall, the UI surfaces a
/// clear error and the existing `.txt` import remains available.
actor EBirdAPIClient {
    static let shared = EBirdAPIClient()

    private let session: URLSession
    /// Histogram downloads must not follow CAS login redirects into an HTML page.
    private let barchartSession: URLSession
    private let apiBase = URL(string: "https://api.ebird.org/v2")!
    private let barchartBase = URL(string: "https://ebird.org/barchartData")!
    private let redirectBlocker = RedirectBlockingDelegate()

    init(session: URLSession = .shared) {
        self.session = session
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = [
            "Accept": "text/tab-separated-values, application/json, text/plain, */*",
        ]
        self.barchartSession = URLSession(
            configuration: config,
            delegate: redirectBlocker,
            delegateQueue: nil
        )
    }

    // MARK: - Hotspot / region search

    func searchHotspots(query raw: String, apiKey: String) async throws -> [EBirdHotspot] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        if let locId = Self.locationId(from: query) {
            let info = try await hotspotInfo(locId: locId, apiKey: apiKey)
            return [info]
        }

        var byId: [String: EBirdHotspot] = [:]

        // Name / region lookup → list hotspots in matching regions, filter by name.
        let regions = try await findRegions(query: query, apiKey: apiKey)
        let ranked = Self.rankRegions(regions, query: query)
        for region in ranked.prefix(6) {
            let hotspots = try await hotspots(
                inRegion: region.code,
                apiKey: apiKey
            )
            for hotspot in hotspots {
                if Self.nameMatches(hotspot.locName, query: query)
                    || ranked.count == 1
                    || Self.isTightRegionMatch(region, query: query) {
                    byId[hotspot.locId] = hotspot
                }
            }
            if byId.count >= 40 { break }
        }

        // If the query looks like a place name and region find was sparse,
        // still surface hotspots whose names contain the query from the best region.
        if byId.isEmpty, let best = ranked.first {
            for hotspot in try await hotspots(inRegion: best.code, apiKey: apiKey) {
                if Self.nameMatches(hotspot.locName, query: query) {
                    byId[hotspot.locId] = hotspot
                }
            }
        }

        return byId.values.sorted {
            $0.locName.localizedCaseInsensitiveCompare($1.locName) == .orderedAscending
        }
    }

    func nearbyHotspots(
        latitude: Double,
        longitude: Double,
        distanceKm: Double = 10,
        excluding locId: String?,
        apiKey: String
    ) async throws -> [EBirdHotspot] {
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
        let hotspots: [EBirdHotspot] = try await getJSON(url: components.url!, apiKey: apiKey)
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
        return try await getJSON(url: url, apiKey: apiKey)
    }

    // MARK: - Frequency / barchart

    /// Downloads checklist frequency for a hotspot (48 week columns = 4×12 months).
    func fetchFrequencyBarchart(
        locId: String,
        apiKey: String,
        beginYear: Int? = nil,
        endYear: Int? = nil
    ) async throws -> ParsedBarchart {
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: Date())
        let eyr = endYear ?? currentYear
        let byr = beginYear ?? max(2006, eyr - 5)
        let sourceFileName = "ebird_\(locId)__\(byr)_\(eyr)_1_12_barchart.txt"

        // Prefer TSV — identical shape to the Files `.txt` import path.
        do {
            let data = try await fetchBarchartData(
                locId: locId,
                beginYear: byr,
                endYear: eyr,
                format: "tsv",
                apiKey: apiKey
            )
            var parsed = try EBirdBarchartParser.parse(data: data, sourceFileName: sourceFileName)
            if parsed.ebirdLocationId == nil {
                parsed.ebirdLocationId = locId
            }
            return parsed
        } catch let error as EBirdAPIError {
            if case .loginRequired = error {
                throw error
            }
            // Fall through to JSON.
        } catch {
            // Fall through to JSON.
        }

        let data = try await fetchBarchartData(
            locId: locId,
            beginYear: byr,
            endYear: eyr,
            format: "json",
            apiKey: apiKey
        )
        return try EBirdBarchartJSONParser.parse(
            data: data,
            locId: locId,
            sourceFileName: sourceFileName
        )
    }

    // MARK: - Internals

    private func findRegions(query: String, apiKey: String) async throws -> [EBirdRegion] {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("ref/region/find"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
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

    private func fetchBarchartData(
        locId: String,
        beginYear: Int,
        endYear: Int,
        format: String,
        apiKey: String
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
        request.setValue(apiKey, forHTTPHeaderField: "X-eBirdApiToken")
        request.setValue(apiKey, forHTTPHeaderField: "x-ebirdapitoken")
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
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            if location.localizedCaseInsensitiveContains("login")
                || location.localizedCaseInsensitiveContains("cassso")
                || location.isEmpty {
                throw EBirdAPIError.loginRequired
            }
            throw EBirdAPIError.loginRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EBirdAPIError.httpStatus(http.statusCode)
        }
        if Self.looksLikeHTMLLogin(data) {
            throw EBirdAPIError.loginRequired
        }
        return data
    }

    private func getJSON<T: Decodable>(url: URL, apiKey: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-eBirdApiToken")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            case 401, 403:
                throw EBirdAPIError.unauthorized
            case 404:
                throw EBirdAPIError.notFound
            default:
                throw EBirdAPIError.httpStatus(http.statusCode)
            }
        } catch let error as EBirdAPIError {
            throw error
        } catch let error as URLError {
            throw EBirdAPIError.network(error)
        } catch {
            throw EBirdAPIError.network(nil)
        }
    }

    private static func locationId(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.range(of: #"^L\d{5,}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func nameMatches(_ name: String, query: String) -> Bool {
        let hay = LocationResolver.normalize(name)
        let needle = LocationResolver.normalize(query)
        guard !needle.isEmpty else { return true }
        if hay.contains(needle) { return true }
        // Match when most query tokens appear in the hotspot name.
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
        // Prefer finer regions (more dashes in code → more specific).
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
    case httpStatus(Int)
    case network(URLError?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your free eBird API key in Settings first (ebird.org/api/keygen)."
        case .unauthorized:
            return "eBird rejected the API key. Check or replace it in Settings."
        case .notFound:
            return "That eBird hotspot or region was not found."
        case .loginRequired:
            return "eBird blocked the frequency download (sign-in wall). Import a barchart .txt instead, or try again later."
        case .badURL:
            return "Could not build the eBird request URL."
        case .invalidResponse:
            return "Unexpected response from eBird."
        case .decodeFailed:
            return "Could not read eBird’s response."
        case .emptyFrequency:
            return "No frequency rows were returned for that hotspot."
        case .httpStatus(let code):
            return "eBird request failed (HTTP \(code))."
        case .network(let error):
            if error?.code == .notConnectedToInternet || error?.code == .networkConnectionLost {
                return "No network connection. Connect and try again, or import a barchart .txt."
            }
            return "Couldn’t reach eBird. Check your connection and try again."
        }
    }
}
