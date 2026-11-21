import Foundation

/// Looks up short appearance/ID lines and published total lengths from English Wikipedia.
/// Used only to fill blanks — never overwrites curated field-guide text.
actor WikipediaFieldClient {
    static let shared = WikipediaFieldClient()

    private let session: URLSession
    private let userAgent =
        "HandyFieldGuide/1.0 (iOS field guide; https://github.com/mulroneyp/mulroneyp; field notes fill)"
    private let apiRoot = URL(string: "https://en.wikipedia.org/w/api.php")!

    private var nextRequestAt: Date = .distantPast
    private let minimumInterval: TimeInterval = 0.55

    struct LookupResult {
        var summary: String
        var lengthCm: [Double]
        var scientificName: String
        var pageTitle: String
    }

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 35
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = false
            config.httpAdditionalHeaders = [
                "User-Agent": userAgent,
                "Accept": "application/json",
            ]
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches description and/or length for one common name. Empty fields mean not found.
    func lookup(
        commonName: String,
        scientificName: String,
        needSummary: Bool,
        needLength: Bool
    ) async throws -> LookupResult {
        try Task.checkCancellation()
        guard needSummary || needLength else {
            return LookupResult(summary: "", lengthCm: [], scientificName: "", pageTitle: "")
        }

        var best = LookupResult(summary: "", lengthCm: [], scientificName: "", pageTitle: "")
        for title in Self.candidateTitles(commonName: commonName, scientificName: scientificName) {
            try Task.checkCancellation()
            guard let page = try await fetchPage(title: title) else { continue }
            if Self.looksUnrelated(page: page, requestedTitle: title) {
                continue
            }

            if best.scientificName.isEmpty {
                best.scientificName = Self.binomial(from: page.extract + " " + page.wikitext)
            }
            if needSummary, best.summary.isEmpty {
                best.summary = Self.appearanceLine(
                    extract: page.extract,
                    wikitext: page.wikitext,
                    commonName: commonName,
                    scientificName: scientificName.isEmpty ? best.scientificName : scientificName
                )
            }
            if needLength, best.lengthCm.isEmpty {
                best.lengthCm = Self.parseLength(from: page.wikitext) ?? []
            }
            best.pageTitle = page.title

            let summaryDone = !needSummary || !best.summary.isEmpty
            let lengthDone = !needLength || !best.lengthCm.isEmpty
            if summaryDone && lengthDone {
                break
            }
        }
        return best
    }

    // MARK: - Network

    private struct PagePayload {
        var title: String
        var extract: String
        var wikitext: String
    }

    private func fetchPage(title: String) async throws -> PagePayload? {
        var components = URLComponents(url: apiRoot, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "prop", value: "extracts|revisions"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "rvprop", value: "content"),
            URLQueryItem(name: "rvslots", value: "main"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        guard let url = components.url else { return nil }
        let data = try await getData(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]],
              let page = pages.first,
              page["missing"] == nil else {
            return nil
        }
        let resolvedTitle = (page["title"] as? String) ?? title
        let extract = (page["extract"] as? String) ?? ""
        var wikitext = ""
        if let revisions = page["revisions"] as? [[String: Any]],
           let first = revisions.first {
            if let slots = first["slots"] as? [String: Any],
               let main = slots["main"] as? [String: Any],
               let content = main["content"] as? String {
                wikitext = content
            } else if let content = first["content"] as? String {
                wikitext = content
            }
        }
        if extract.isEmpty && wikitext.isEmpty {
            return nil
        }
        return PagePayload(title: resolvedTitle, extract: extract, wikitext: wikitext)
    }

    private func getData(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let now = Date()
        if now < nextRequestAt {
            let delay = nextRequestAt.timeIntervalSince(now)
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        nextRequestAt = Date().addingTimeInterval(minimumInterval)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Titles

    nonisolated static func candidateTitles(commonName: String, scientificName: String) -> [String] {
        var titles: [String] = []
        let trimmedSci = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableBinomial(trimmedSci) {
            titles.append(trimmedSci)
        }
        titles.append(contentsOf: [
            commonName,
            commonName.replacingOccurrences(of: "-", with: " "),
            "\(commonName) (bird)",
            commonName.replacingOccurrences(of: "Grey", with: "Gray")
                .replacingOccurrences(of: "grey", with: "gray"),
        ])
        let parts = commonName.split(separator: " ").map(String.init)
        if let first = parts.first {
            let sentence = first.prefix(1).uppercased() + first.dropFirst().lowercased()
                + (parts.count > 1 ? " " + parts.dropFirst().map { $0.lowercased() }.joined(separator: " ") : "")
            titles.append(sentence)
            titles.append("\(sentence) (bird)")
        }
        var seen = Set<String>()
        var ordered: [String] = []
        for title in titles {
            let key = title.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(title)
        }
        return ordered
    }

    // MARK: - Appearance line

    nonisolated static func appearanceLine(
        extract: String,
        wikitext: String,
        commonName: String,
        scientificName: String
    ) -> String {
        let fromDescription = cleanAppearance(
            plainText(descriptionSection(wikitext)),
            commonName: commonName,
            scientificName: scientificName
        )
        if !fromDescription.isEmpty {
            return fromDescription
        }
        return cleanAppearance(
            extract,
            commonName: commonName,
            scientificName: scientificName
        )
    }

    nonisolated static func cleanAppearance(_ raw: String, commonName: String, scientificName: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // Keep the first one or two sentences.
        let sentences = splitSentences(text)
        text = sentences.prefix(2).joined(separator: " ")
        text = stripTaxonomicLead(text, commonName: commonName, scientificName: scientificName)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 220 {
            text = truncateAtWord(text, limit: 220)
        }
        guard text.count >= 18 else { return "" }

        // Reject import plumbing / habitat-only / range-only lines.
        let probe = Species(
            id: "probe",
            commonName: commonName,
            scientificName: scientificName.isEmpty ? "—" : scientificName,
            aliases: [],
            alsoCalled: [],
            alsoScientific: [],
            tags: [],
            dimorphic: false,
            origin: "native",
            status: "imported",
            group: "imported",
            strata: ["mid"],
            activeTimes: [],
            summary: text,
            habitat: "",
            sexes: "",
            stratumNote: "",
            photos: []
        )
        let accepted = SpeciesDescription.text(for: probe)
        guard !accepted.isEmpty else { return "" }

        let lower = accepted.lowercased()
        if looksLikeRangeOnly(lower) { return "" }
        if looksLikeHabitatOnly(lower) { return "" }
        return accepted
    }

    nonisolated private static func stripTaxonomicLead(_ text: String, commonName: String, scientificName: String) -> String {
        var result = text
        let escapedCommon = NSRegularExpression.escapedPattern(for: commonName)
        let patterns = [
            #"^The\s+"# + escapedCommon + #"\s*\([^)]+\)\s+(?:is|are|was|were)\s+(?:a|an|the)\s+"#,
            #"^The\s+"# + escapedCommon + #"\s+(?:is|are|was|were)\s+(?:a|an|the)\s+"#,
            #"^"# + escapedCommon + #"\s*\([^)]+\)\s+(?:is|are|was|were)\s+(?:a|an|the)\s+"#,
        ]
        if isUsableBinomial(scientificName) {
            let escapedSci = NSRegularExpression.escapedPattern(for: scientificName)
            // "Binomial is a ..."
            let sciLead = #"^"# + escapedSci + #"\s+(?:is|are)\s+(?:a|an|the)\s+"#
            if let regex = try? NSRegularExpression(pattern: sciLead, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            let replaced = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            if replaced != result {
                result = replaced
                break
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first {
            result = String(first).uppercased() + result.dropFirst()
        }
        return result
    }

    nonisolated private static func looksLikeRangeOnly(_ lower: String) -> Bool {
        let rangeTokens = ["found in", "native to", "occurs in", "distributed", "range from", "throughout"]
        let appearanceTokens = [
            "plumage", "bill", "wing", "tail", "throat", "breast", "back", "crown",
            "streak", "barred", "rufous", "olive", "yellow", "black", "white", "brown",
            "grey", "gray", "green", "blue", "crest", "eye", "size", "small", "large",
            "long", "short", "male", "female", "dimorphic",
        ]
        let hasRange = rangeTokens.contains { lower.contains($0) }
        let hasAppearance = appearanceTokens.contains { lower.contains($0) }
        return hasRange && !hasAppearance
    }

    nonisolated private static func looksLikeHabitatOnly(_ lower: String) -> Bool {
        let habitatLeads = [
            "edges, clearings", "garden and edge", "canopy and edge",
            "lives in", "inhabits", "habitat is", "prefers forest",
        ]
        return habitatLeads.contains { lower.contains($0) }
    }

    // MARK: - Length parsing

    /// Species where a single Length figure misleads the sparrow–ostrich scale.
    nonisolated static let intentionalBlankLengthIds: Set<String> = [
        "resplendent-quetzal",
        "imported-resplendent-quetzal",
    ]

    nonisolated static func shouldSkipLength(commonName: String, speciesId: String) -> Bool {
        let low = commonName.lowercased()
        if low.contains("(hybrid)") || low.contains("(form)") || low.contains(" x ") || low.contains(" × ") {
            return true
        }
        let slug = SpeciesCatalog.slug(commonName)
        if intentionalBlankLengthIds.contains(slug) || intentionalBlankLengthIds.contains(speciesId) {
            return true
        }
        return false
    }

    nonisolated static func parseLength(from wikitext: String) -> [Double]? {
        for window in lengthWindows(wikitext) {
            if let cm = firstConvertCm(in: window) { return cm }
            if let inches = firstConvertInches(in: window) { return inches }
            if let prose = firstProseLength(in: window) { return prose }
        }
        return nil
    }

    nonisolated private static func lengthWindows(_ text: String) -> [String] {
        var windows: [String] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        func appendWindow(around range: NSRange, before: Int, after: Int) {
            let start = max(0, range.location - before)
            let end = min(ns.length, range.location + range.length + after)
            windows.append(ns.substring(with: NSRange(location: start, length: end - start)))
        }

        let patterns: [(String, Int, Int)] = [
            (#"(?i)'''\s*(?:total\s+)?(?:body\s+)?length\s*'''"#, 120, 500),
            (#"(?i)\|\s*(?:total\s+)?(?:body\s+)?length\s*\|"#, 0, 400),
            (#"(?i)(?:total\s+)?(?:body\s+)?length[^\n]{0,80}"#, 160, 700),
        ]
        for (pattern, before, after) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, options: [], range: full) {
                let chunk = ns.substring(with: match.range)
                if chunk.range(of: #"\b(?:egg|tail|wing|tarsus|culmen|bill)\s+length\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    continue
                }
                appendWindow(around: match.range, before: before, after: after)
            }
        }

        let desc = descriptionSection(text)
        if !desc.isEmpty {
            if let regex = try? NSRegularExpression(
                pattern: #"(?i)(?:is|are|measures?|measure)\s+\{\{(?:convert|cvt)\|[^}]{0,80}\}\}\s*long"#
            ) {
                let descRange = NSRange(location: 0, length: (desc as NSString).length)
                for match in regex.matches(in: desc, options: [], range: descRange) {
                    let start = max(0, match.range.location - 20)
                    let end = min((desc as NSString).length, match.range.location + match.range.length + 40)
                    windows.append((desc as NSString).substring(with: NSRange(location: start, length: end - start)))
                }
            }
            if windows.isEmpty {
                windows.append(String(desc.prefix(2500)))
            }
        }
        return windows
    }

    nonisolated private static func firstConvertCm(in window: String) -> [Double]? {
        let pattern =
            #"\{\{\s*(?:convert|cvt)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*"#
            + #"(?:\|\s*(?:to(?:\([^)]*\))?|-|–|—|and)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*)?"#
            + #"\|\s*cm\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = window as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: window, options: [], range: full) {
            if precedingIsWingspan(window, index: match.range.location) { continue }
            guard let low = double(in: ns, range: match.range(at: 1)) else { continue }
            let high = match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound
                ? double(in: ns, range: match.range(at: 2))
                : nil
            if let normalized = normalizeRange(low: low, high: high) {
                return normalized
            }
        }
        return nil
    }

    nonisolated private static func firstConvertInches(in window: String) -> [Double]? {
        let pattern =
            #"\{\{\s*(?:convert|cvt)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*"#
            + #"(?:\|\s*(?:to(?:\([^)]*\))?|-|–|—|and)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*)?"#
            + #"\|\s*in\s*\|\s*(?:cm|mm)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = window as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: window, options: [], range: full) {
            if precedingIsWingspan(window, index: match.range.location) { continue }
            guard let lowIn = double(in: ns, range: match.range(at: 1)) else { continue }
            let highIn = match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound
                ? double(in: ns, range: match.range(at: 2))
                : nil
            if let normalized = normalizeRange(low: lowIn * 2.54, high: highIn.map { $0 * 2.54 }) {
                return normalized
            }
        }
        return nil
    }

    nonisolated private static func firstProseLength(in window: String) -> [Double]? {
        let patterns: [(String, Bool)] = [
            (
                #"(?i)(?:total\s+)?(?:body\s+)?length[^\n.]{0,60}?(\d+(?:\.\d+)?)\s*(?:to|–|-)\s*(\d+(?:\.\d+)?)\s*cm"#,
                false
            ),
            (
                #"(?i)(\d+(?:\.\d+)?)\s*(?:to|–|-)\s*(\d+(?:\.\d+)?)\s*cm[^\n.]{0,40}(?:in\s+)?(?:overall\s+)?(?:total\s+)?(?:body\s+)?length"#,
                false
            ),
            (
                #"(?i)(?:total\s+)?(?:body\s+)?length[^\n.]{0,60}?(\d+(?:\.\d+)?)\s*(?:to|–|-)\s*(\d+(?:\.\d+)?)\s*(?:in(?:ch(?:es)?)?)\b"#,
                true
            ),
            (
                #"(?i)(?:total\s+)?(?:body\s+)?length[^\n.]{0,60}?(\d+(?:\.\d+)?)\s*cm"#,
                false
            ),
        ]
        let ns = window as NSString
        let full = NSRange(location: 0, length: ns.length)
        for (pattern, inches) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            guard let match = regex.firstMatch(in: window, options: [], range: full) else { continue }
            let matched = ns.substring(with: match.range)
            if matched.range(of: #"(?i)egg|width|bill|wing"#, options: .regularExpression) != nil {
                continue
            }
            guard let low = double(in: ns, range: match.range(at: 1)) else { continue }
            var high: Double?
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                high = double(in: ns, range: match.range(at: 2))
            }
            let scale: Double = inches ? 2.54 : 1
            if let normalized = normalizeRange(low: low * scale, high: high.map { $0 * scale }) {
                return normalized
            }
        }
        return nil
    }

    nonisolated private static func precedingIsWingspan(_ text: String, index: Int) -> Bool {
        let start = max(0, index - 48)
        let prior = (text as NSString).substring(with: NSRange(location: start, length: index - start)).lowercased()
        return prior.range(of: #"wingspan|wing\s*span|\bspans\b|\bspan\b|across the wings"#, options: .regularExpression) != nil
    }

    nonisolated private static func normalizeRange(low: Double, high: Double?) -> [Double]? {
        func roundCm(_ value: Double) -> Double {
            let tenths = (value * 2).rounded() / 2
            if abs(tenths - tenths.rounded()) < 0.05 {
                return tenths.rounded()
            }
            return tenths
        }
        var values = [roundCm(low)]
        if let high {
            values.append(roundCm(high))
        }
        values.sort()
        if values.contains(where: { $0 < 5 || $0 > 280 }) { return nil }
        if values.count == 2, abs(values[1] - values[0]) < 0.05 {
            return [values[0]]
        }
        return values
    }

    nonisolated private static func double(in ns: NSString, range: NSRange) -> Double? {
        guard range.location != NSNotFound else { return nil }
        return Double(ns.substring(with: range))
    }

    // MARK: - Wikitext helpers

    nonisolated private static func descriptionSection(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)==\s*Description\s*=="#) else {
            return ""
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: full) else {
            return ""
        }
        let start = match.range.location + match.range.length
        let rest = ns.substring(from: start)
        if let next = try? NSRegularExpression(pattern: #"\n==\s*[^=].*?=="#),
           let nextMatch = next.firstMatch(
            in: rest,
            options: [],
            range: NSRange(location: 0, length: (rest as NSString).length)
           ) {
            return (rest as NSString).substring(to: nextMatch.range.location)
        }
        return String(rest.prefix(6000))
    }

    nonisolated private static func plainText(_ wikitext: String) -> String {
        var text = wikitext
        // Drop templates.
        while let regex = try? NSRegularExpression(pattern: #"\{\{[^{}]*\}\}"#),
              regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil {
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: ""
            )
        }
        text = text.replacingOccurrences(of: #"\[\[([^|\]]*\|)?([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"'''?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func looksUnrelated(page: PagePayload, requestedTitle: String) -> Bool {
        let head = (page.extract + "\n" + String(page.wikitext.prefix(800))).lowercased()
        if head.contains("may refer to"),
           !head.contains("bird"),
           !requestedTitle.lowercased().contains("(bird)") {
            return true
        }
        if head.contains("legendary") || head.contains("wizard") {
            return true
        }
        return false
    }

    nonisolated private static func binomial(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b([A-Z][a-z]+)\s+([a-z]{2,})\b"#
        ) else { return "" }
        let ns = text as NSString
        let full = NSRange(location: 0, length: min(ns.length, 1200))
        for match in regex.matches(in: text, options: [], range: full) {
            let candidate = ns.substring(with: match.range)
            if isUsableBinomial(candidate) {
                return candidate
            }
        }
        return ""
    }

    nonisolated private static func isUsableBinomial(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "—", trimmed != "-", !trimmed.isEmpty else { return false }
        let parts = trimmed.split(separator: " ")
        guard parts.count == 2 else { return false }
        let genus = parts[0]
        let species = parts[1]
        guard let gFirst = genus.first, gFirst.isUppercase else { return false }
        guard let sFirst = species.first, sFirst.isLowercase else { return false }
        return genus.dropFirst().allSatisfy(\.isLetter) && species.allSatisfy(\.isLetter)
    }

    nonisolated private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            sentences.append(trailing)
        }
        return sentences
    }

    nonisolated private static func truncateAtWord(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        let head = String(text[..<idx])
        if let space = head.lastIndex(of: " ") {
            return String(head[..<space]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
