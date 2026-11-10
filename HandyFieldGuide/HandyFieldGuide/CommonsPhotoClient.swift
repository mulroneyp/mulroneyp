import Foundation
import UIKit

/// Wikimedia Commons lookup for openly licensed bird photos.
/// Mirrors the licence and search rules used by the offline enrich scripts.
actor CommonsPhotoClient {
    static let shared = CommonsPhotoClient()

    private let session: URLSession
    private let userAgent = "HandyFieldGuide/1.0 (iOS field guide; https://github.com/mulroneyp/mulroneyp; open-licence photos)"
    private let apiRoot = URL(string: "https://commons.wikimedia.org/w/api.php")!
    private let wikidataRoot = URL(string: "https://www.wikidata.org/w/api.php")!

    private var nextRequestAt: Date = .distantPast
    private let minimumInterval: TimeInterval = 0.85

    struct Candidate {
        var title: String
        var mime: String
        var downloadURL: URL
        var description: String
        var artist: String
        var license: String
        var licenseURL: String
        var width: Int
        var score: Int
    }

    struct SpeciesQuery {
        var commonName: String
        var scientificName: String
        var alsoCalled: [String]
        var alsoScientific: [String]
        var aliases: [String]
    }

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = false
            config.httpAdditionalHeaders = [
                "User-Agent": userAgent,
                "Accept": "application/json",
            ]
            self.session = URLSession(configuration: config)
        }
    }

    func resolveScientificName(commonName: String, hinted: String) async -> String {
        let trimmed = hinted.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableBinomial(trimmed) { return trimmed }

        let title = commonName.replacingOccurrences(of: " ", with: "_")
        var components = URLComponents(url: wikidataRoot, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "sites", value: "enwiki"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "props", value: "claims"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return "" }
        do {
            let data = try await getData(url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entities = json["entities"] as? [String: Any] else {
                return ""
            }
            for (_, value) in entities {
                guard let entity = value as? [String: Any],
                      entity["missing"] == nil,
                      let claims = entity["claims"] as? [String: Any],
                      let p225 = claims["P225"] as? [[String: Any]] else {
                    continue
                }
                for claim in p225 {
                    if let mainsnak = claim["mainsnak"] as? [String: Any],
                       let datavalue = mainsnak["datavalue"] as? [String: Any],
                       let binomial = datavalue["value"] as? String,
                       isUsableBinomial(binomial) {
                        return binomial
                    }
                }
            }
        } catch {
            return ""
        }
        return ""
    }

    /// Finds the best open-licence photo for a role. Returns nil on miss / cancel / network failure.
    func choosePhoto(
        species: SpeciesQuery,
        role: String,
        avoidTitles: Set<String>
    ) async throws -> Candidate? {
        try Task.checkCancellation()
        let titles = try await candidateTitles(species: species, role: role, avoid: avoidTitles)
        guard !titles.isEmpty else { return nil }

        var best: Candidate?
        var bestScore = -10_000
        let capped = Array(titles.prefix(72))
        var index = 0
        while index < capped.count {
            try Task.checkCancellation()
            let end = min(index + 12, capped.count)
            let chunk = Array(capped[index..<end])
            index = end
            let info = try await imageInfo(titles: chunk)
            for title in chunk {
                guard var item = info[title] else { continue }
                guard let score = scoreCandidate(species: species, role: role, item: item) else { continue }
                item.score = score
                if score > bestScore {
                    bestScore = score
                    best = item
                }
            }
            if role == "male" || role == "female", bestScore >= 48 { break }
            if role == "either" || role == "unsexed", bestScore >= 18 { break }
        }
        guard let best, bestScore >= 8 else { return nil }
        return best
    }

    func downloadJPEG(from url: URL, maxPixel: CGFloat = 1000) async throws -> (Data, Int, Int) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request(url))
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        // UIKit image rendering stays on the main actor.
        let resized = await MainActor.run {
            Self.resizedJPEG(image, maxPixel: maxPixel)
        }
        return (resized.data, resized.width, resized.height)
    }

    // MARK: - Search

    private func candidateTitles(
        species: SpeciesQuery,
        role: String,
        avoid: Set<String>
    ) async throws -> [String] {
        var titles: [String] = []
        let binomials = usableBinomials(from: species)
        for binomial in binomials.prefix(3) {
            titles.append(contentsOf: try await categoryFiles("Category:\(binomial)"))
            if role == "male" {
                titles.append(contentsOf: try await categoryFiles("Category:Male \(binomial)"))
            } else if role == "female" {
                titles.append(contentsOf: try await categoryFiles("Category:Female \(binomial)"))
            }
        }
        for alias in species.alsoCalled.prefix(2) {
            titles.append(contentsOf: try await categoryFiles("Category:\(alias)"))
        }
        for query in buildPhotoQueries(species: species, role: role) {
            titles.append(contentsOf: try await searchFiles(query, limit: 30))
        }

        var seen = Set<String>()
        var ordered: [String] = []
        for title in titles where !avoid.contains(title) {
            if seen.insert(title).inserted {
                ordered.append(title)
            }
        }
        return ordered
    }

    private func buildPhotoQueries(species: SpeciesQuery, role: String) -> [String] {
        var labels: [String] = []
        for value in [species.commonName] + species.alsoCalled + species.aliases {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "—", trimmed != "-", !labels.contains(trimmed) {
                labels.append(trimmed)
            }
        }
        let binomials = usableBinomials(from: species)
        var queries: [String] = []

        func add(_ query: String) {
            let cleaned = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty, !cleaned.contains("—"), !queries.contains(cleaned) else { return }
            queries.append(cleaned)
        }

        let primarySex: String? = role == "male" ? "male" : (role == "female" ? "female" : nil)
        let extraSex = sexKeywords(role).filter { $0 != primarySex }.prefix(2)
        if let primarySex {
            for binomial in binomials.prefix(3) {
                add("\(binomial) \(primarySex)")
                add("\"\(binomial)\" \(primarySex)")
            }
            for label in labels.prefix(4) {
                add("\(label) \(primarySex)")
                add("\"\(label)\" \(primarySex)")
            }
            for sex in extraSex {
                for binomial in binomials.prefix(2) { add("\(binomial) \(sex)") }
                for label in labels.prefix(2) { add("\(label) \(sex)") }
            }
        }
        for binomial in binomials.prefix(3) {
            add(binomial)
            for label in labels.prefix(3) { add("\(label) \(binomial)") }
        }
        for label in labels.prefix(4) { add(label) }
        return Array(queries.prefix(18))
    }

    private func sexKeywords(_ role: String) -> [String] {
        switch role {
        case "male": return ["male", "adult male", "♂", "macho", "männchen"]
        case "female": return ["female", "adult female", "♀", "hembra", "weibchen"]
        default: return []
        }
    }

    private func searchFiles(_ query: String, limit: Int) async throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("—"), trimmed != "-", trimmed != "?" else { return [] }
        let json = try await api([
            "action": "query",
            "list": "search",
            "srsearch": trimmed,
            "srnamespace": "6",
            "srlimit": "\(min(max(limit, 1), 50))",
        ])
        let hits = (((json["query"] as? [String: Any])?["search"]) as? [[String: Any]]) ?? []
        return hits.compactMap { hit in
            let title = hit["title"] as? String ?? ""
            let lower = title.lowercased()
            guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp") else {
                return nil
            }
            return title
        }
    }

    private func categoryFiles(_ title: String) async throws -> [String] {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("—") else { return [] }
        if !title.hasPrefix("Category:") {
            title = "Category:\(title)"
        }
        let json = try await api([
            "action": "query",
            "list": "categorymembers",
            "cmtitle": title,
            "cmtype": "file",
            "cmlimit": "50",
        ])
        let hits = (((json["query"] as? [String: Any])?["categorymembers"]) as? [[String: Any]]) ?? []
        return hits.compactMap { hit in
            let name = hit["title"] as? String ?? ""
            let lower = name.lowercased()
            guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp") else {
                return nil
            }
            return name
        }
    }

    private func imageInfo(titles: [String]) async throws -> [String: Candidate] {
        guard !titles.isEmpty else { return [:] }
        var found: [String: Candidate] = [:]
        for start in stride(from: 0, to: titles.count, by: 8) {
            try Task.checkCancellation()
            let end = min(start + 8, titles.count)
            let chunk = Array(titles[start..<end])
            let json = try await api([
                "action": "query",
                "titles": chunk.joined(separator: "|"),
                "prop": "imageinfo",
                "iiprop": "url|size|mime|extmetadata",
                "iiurlwidth": "1200",
            ])
            let pages = ((json["query"] as? [String: Any])?["pages"] as? [String: Any]) ?? [:]
            for (_, value) in pages {
                guard let page = value as? [String: Any],
                      let title = page["title"] as? String,
                      let infos = page["imageinfo"] as? [[String: Any]],
                      let info = infos.first else {
                    continue
                }
                let meta = info["extmetadata"] as? [String: Any] ?? [:]
                let license = plain(metaValue(meta, "LicenseShortName"))
                guard Self.licenseOK(license) else { continue }
                let thumb = info["thumburl"] as? String
                let full = info["url"] as? String
                guard let download = URL(string: thumb ?? full ?? "") else { continue }
                found[title] = Candidate(
                    title: title,
                    mime: ((info["mime"] as? String) ?? "").lowercased(),
                    downloadURL: download,
                    description: String(plain(metaValue(meta, "ImageDescription")).prefix(400)),
                    artist: String(plain(metaValue(meta, "Artist")).prefix(180)),
                    license: license,
                    licenseURL: plain(metaValue(meta, "LicenseUrl")),
                    width: info["width"] as? Int ?? 0,
                    score: 0
                )
            }
        }
        return found
    }

    // MARK: - Scoring / licence

    private func scoreCandidate(species: SpeciesQuery, role: String, item: Candidate) -> Int? {
        let text = "\(item.title) \(item.description)".lowercased()
        if hardSkip(text) || !nameMatch(text, species: species) { return nil }
        var score = 12
        let (male, female) = sexFlags(text)
        switch role {
        case "male":
            score += (male && !female) ? 36 : -28
        case "female":
            score += (female && !male) ? 36 : -28
        default:
            score += 6
            if male != female { score -= 4 }
        }
        if text.contains("captive") || text.contains("zoo") || text.contains("aviary") {
            score -= 8
        }
        if item.width >= 800 { score += 2 }
        return score
    }

    private func nameMatch(_ text: String, species: SpeciesQuery) -> Bool {
        let needles = speciesNameNeedles(species)
        if needles.contains(where: { !$0.isEmpty && text.contains($0) }) {
            return true
        }
        for label in [species.commonName] + species.alsoCalled {
            let tokens = nameTokens(label)
            if tokens.count >= 2, tokens.filter({ text.contains($0) }).count >= 2 {
                return true
            }
        }
        let parts = species.scientificName.lowercased().split(separator: " ").map(String.init)
        if parts.count >= 2, text.contains(parts[0]), text.contains(parts[1]) {
            return true
        }
        return false
    }

    private func speciesNameNeedles(_ species: SpeciesQuery) -> [String] {
        var needles: [String] = []
        for value in [species.commonName, species.scientificName] + species.alsoCalled + species.alsoScientific + species.aliases {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !text.isEmpty, text != "—", text != "-", text != "?", !needles.contains(text) {
                needles.append(text)
            }
        }
        return needles
    }

    private func nameTokens(_ value: String) -> [String] {
        let stop: Set<String> = [
            "the", "a", "an", "and", "or", "of", "common", "northern", "southern",
            "eastern", "western", "american", "bird", "birds",
        ]
        return value.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0) }
    }

    private func sexFlags(_ text: String) -> (Bool, Bool) {
        let male = text.range(of: #"\bmales?\b|♂|\bmacho\b|\bmännchen\b"#, options: .regularExpression) != nil
        let female = text.range(of: #"\bfemales?\b|♀|\bhembra\b|\bweibchen\b"#, options: .regularExpression) != nil
        return (male, female)
    }

    private func hardSkip(_ text: String) -> Bool {
        let banned = [
            "juvenile", "immature", "chick", "nestling", "fledgling", "egg",
            "painting", "illustration", "stamp", "drawing", "artwork", "icon",
            "range map", "distribution", "locator", "diagram", "skeleton",
            "museum specimen", "study skin", "taxiderm",
            "keulemans", "monograph", "biologia centrali", "castelnau",
            "lithograph", "engraving", "hand-colored", "hand colored",
            "naturalis", "rmnh", "specimen", "employee", "uniform",
        ]
        if banned.contains(where: { text.contains($0) }) { return true }
        return text.range(of: #"\bplates?\b"#, options: .regularExpression) != nil
    }

    static func licenseOK(_ short: String) -> Bool {
        let text = short.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let spaced = text.replacingOccurrences(of: "-", with: " ")
        if spaced.range(of: #"\bnc\b|noncommercial|non-commercial"#, options: .regularExpression) != nil {
            return false
        }
        if spaced.range(of: #"\bnd\b|noderiv|no derivatives|no-deriv"#, options: .regularExpression) != nil {
            return false
        }
        let flags = [
            "cc0", "cc-zero", "public domain", "publicdomain", "pdm",
            "cc by", "cc-by", "gfdl", "free documentation",
        ]
        if flags.contains(where: { text.contains($0) || spaced.contains($0) }) {
            return true
        }
        let exact: Set<String> = ["pd", "pdm", "no restrictions", "copyrighted free use"]
        return exact.contains(spaced) || exact.contains(text)
    }

    // MARK: - Networking

    private func api(_ params: [String: String]) async throws -> [String: Any] {
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "format", value: "json"))
        var components = URLComponents(url: apiRoot, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }

        var lastError: Error = URLError(.unknown)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            await waitForRateLimit()
            do {
                let data = try await getData(url)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let json = object as? [String: Any] else {
                    throw URLError(.cannotParseResponse)
                }
                return json
            } catch {
                lastError = error
                let pause: UInt64
                if let urlError = error as? URLError, urlError.code == .badServerResponse {
                    pause = UInt64(30_000_000_000 * (attempt + 1))
                } else {
                    pause = UInt64(8_000_000_000 * (attempt + 1))
                }
                try await Task.sleep(nanoseconds: pause)
            }
        }
        throw lastError
    }

    private func waitForRateLimit() async {
        let now = Date()
        let wait = nextRequestAt.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        nextRequestAt = Date().addingTimeInterval(minimumInterval)
    }

    private func getData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(url))
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        return data
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func usableBinomials(from species: SpeciesQuery) -> [String] {
        var out: [String] = []
        for value in [species.scientificName] + species.alsoScientific {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableBinomial(trimmed), !out.contains(trimmed) {
                out.append(trimmed)
            }
        }
        return out
    }

    private func isUsableBinomial(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "—", trimmed != "-", trimmed != "?", trimmed.contains(" ") else { return false }
        return trimmed.range(of: #"^[A-Z][a-z]+ [a-z]+$"#, options: .regularExpression) != nil
    }

    private func metaValue(_ meta: [String: Any], _ key: String) -> String {
        ((meta[key] as? [String: Any])?["value"] as? String) ?? ""
    }

    private func plain(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resizedJPEG(_ image: UIImage, maxPixel: CGFloat) -> (data: Data, width: Int, height: Int) {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxPixel ? maxPixel / longest : 1
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        let data = rendered.jpegData(compressionQuality: 0.74) ?? Data()
        return (data, Int(target.width), Int(target.height))
    }

    static func filePageURL(title: String) -> String {
        let name = title.split(separator: ":", maxSplits: 1).last.map(String.init) ?? title
        let underscored = name.replacingOccurrences(of: " ", with: "_")
        let encoded = underscored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? underscored
        return "https://commons.wikimedia.org/wiki/File:\(encoded)"
    }

    static func makePhoto(
        speciesId: String,
        commonName: String,
        role: String,
        candidate: Candidate,
        relativePath: String,
        width: Int,
        height: Int
    ) -> Photo {
        let label: String
        let alt: String
        switch role {
        case "male":
            label = "Male"
            alt = "Male \(commonName)"
        case "female":
            label = "Female"
            alt = "Female \(commonName)"
        case "either":
            label = "Sexes look alike"
            alt = "\(commonName). Males and females look alike."
        case "illustration":
            label = "Historical illustration"
            alt = "Historical illustration of \(commonName)."
        default:
            label = "Sex not labeled"
            alt = "\(commonName). The source photo is not labeled male or female."
        }
        return Photo(
            role: role,
            label: label,
            src: relativePath,
            alt: alt,
            width: width,
            height: height,
            author: candidate.artist.isEmpty ? "Wikimedia Commons contributor" : candidate.artist,
            license: candidate.license,
            licenseUrl: candidate.licenseURL,
            sourceUrl: Self.filePageURL(title: candidate.title),
            file: candidate.title
        )
    }
}
