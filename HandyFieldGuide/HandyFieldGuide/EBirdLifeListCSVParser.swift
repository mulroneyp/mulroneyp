import Foundation

/// One species row after parsing an eBird life-list CSV (or aggregating My Data).
struct ParsedLifeListEntry: Hashable {
    var commonName: String
    var scientificName: String
    var taxonOrder: Int?
    var category: String
    var count: String?
    var exotic: String?
    var countable: Bool
    /// First recorded sighting date string as exported (when present).
    var firstRecordedDate: String?
    /// First recorded location label (place, optionally with S/P).
    var firstRecordedLocation: String?
    var firstLocId: String?
    var firstSubId: String?
    /// ISO-ish country code from eBird S/P (e.g. `US` from `US-TX`), when present.
    var firstRecordedCountryCode: String?
    /// Most recent recorded sighting date string (when present).
    var lastRecordedDate: String?
    var lastRecordedLocation: String?
    var lastLocId: String?
    var lastSubId: String?
    var lastRecordedCountryCode: String?
}

struct ParsedLifeList: Hashable {
    var sourceFileName: String
    var entries: [ParsedLifeListEntry]
    /// Rows kept after applying Countable / species rules (or unique species after My Data aggregation).
    var keptCount: Int { entries.count }
    /// Observation / CSV body rows considered before filtering or aggregation.
    var rawRowCount: Int
    /// True when first/last were derived by aggregating a full My Data export.
    var aggregatedFromMyData: Bool
}

enum EBirdLifeListCSVParser {
    enum ParseError: LocalizedError {
        case emptyFile
        case missingHeader
        case missingCommonNameColumn

        var errorDescription: String? {
            switch self {
            case .emptyFile:
                return "That file is empty."
            case .missingHeader:
                return "That file does not look like an eBird life list CSV (missing a header row)."
            case .missingCommonNameColumn:
                return "That CSV is missing a Common Name column. Export a Life List (or My Data) from eBird."
            }
        }
    }

    static func parse(data: Data, sourceFileName: String) throws -> ParsedLifeList {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.emptyFile
        }
        return try parse(text: text, sourceFileName: sourceFileName)
    }

    static func parse(text: String, sourceFileName: String) throws -> ParsedLifeList {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let headerLine = lines.first else { throw ParseError.emptyFile }

        let headers = parseCSVLine(headerLine).map { normalizeHeader($0) }
        guard !headers.isEmpty else { throw ParseError.missingHeader }

        let index = columnIndex(headers)
        guard index.common != nil else { throw ParseError.missingCommonNameColumn }

        // Full personal export: one row per checklist observation — derive first + last.
        if index.submissionID != nil {
            return try parseMyData(lines: lines, index: index, sourceFileName: sourceFileName)
        }
        return try parseLifeListTable(lines: lines, index: index, sourceFileName: sourceFileName)
    }

    // MARK: - Life list table (one row per taxon)

    private static func parseLifeListTable(
        lines: [String],
        index: ColumnIndex,
        sourceFileName: String
    ) throws -> ParsedLifeList {
        guard let commonIdx = index.common else { throw ParseError.missingCommonNameColumn }
        let hasCountableColumn = index.countable != nil

        var entries: [ParsedLifeListEntry] = []
        var rawRowCount = 0
        var seenKeys = Set<String>()

        for line in lines.dropFirst() {
            let cols = parseCSVLine(line)
            guard let common = field(cols, commonIdx), !common.isEmpty else { continue }
            rawRowCount += 1

            let category = (field(cols, index.category) ?? "species").lowercased()
            let countable = resolveCountable(
                raw: field(cols, index.countable),
                hasCountableColumn: hasCountableColumn,
                category: category,
                commonName: common
            )
            guard countable else { continue }

            let scientific = field(cols, index.scientific) ?? ""
            let key = matchKey(common: common, scientific: scientific)
            guard seenKeys.insert(key).inserted else { continue }

            let taxonOrder = intField(cols, index.taxonOrder)
            let state = field(cols, index.stateProvince)
            let country = countryCode(fromStateProvince: state)
            let date = field(cols, index.date)
            let location = field(cols, index.location)
            let locId = field(cols, index.locId)
            let subId = field(cols, index.subId)

            // Explicit first/last columns when a spreadsheet includes them.
            var firstDate = field(cols, index.firstDate)
            var firstLocation = composedLocation(place: field(cols, index.firstLocation) ?? location, state: state)
            let lastDate = field(cols, index.lastDate)
            let lastLocation = composedLocation(place: field(cols, index.lastLocation), state: state)

            // Classic eBird life-list export: single Date + Location = first recorded
            // (Sightings Lists default). Last stays empty unless Last* columns exist.
            if firstDate == nil, let date, !date.isEmpty {
                firstDate = date
            }
            if firstLocation == nil || firstLocation?.isEmpty == true {
                firstLocation = composedLocation(place: location, state: state)
            }
            // If only Last* were filled and Date was empty, leave first blank.

            let resolvedFirstLocation = emptyToNil(firstLocation)
            let resolvedLastLocation = emptyToNil(lastLocation)

            entries.append(
                ParsedLifeListEntry(
                    commonName: common,
                    scientificName: scientific,
                    taxonOrder: taxonOrder,
                    category: category.isEmpty ? "species" : category,
                    count: field(cols, index.count),
                    exotic: field(cols, index.exotic),
                    countable: true,
                    firstRecordedDate: emptyToNil(firstDate),
                    firstRecordedLocation: resolvedFirstLocation,
                    firstLocId: locId,
                    firstSubId: subId,
                    firstRecordedCountryCode: resolvedFirstLocation != nil
                        ? (country ?? countryCode(fromLocation: resolvedFirstLocation))
                        : nil,
                    lastRecordedDate: emptyToNil(lastDate),
                    lastRecordedLocation: resolvedLastLocation,
                    lastLocId: field(cols, index.lastLocId) ?? (lastDate != nil ? locId : nil),
                    lastSubId: field(cols, index.lastSubId),
                    lastRecordedCountryCode: resolvedLastLocation != nil
                        ? (country ?? countryCode(fromLocation: resolvedLastLocation))
                        : nil
                )
            )
        }

        sortEntries(&entries)
        return ParsedLifeList(
            sourceFileName: sourceFileName,
            entries: entries,
            rawRowCount: rawRowCount,
            aggregatedFromMyData: false
        )
    }

    // MARK: - My Data (many rows → first + last per species)

    private static func parseMyData(
        lines: [String],
        index: ColumnIndex,
        sourceFileName: String
    ) throws -> ParsedLifeList {
        guard let commonIdx = index.common else { throw ParseError.missingCommonNameColumn }

        struct Acc {
            var commonName: String
            var scientificName: String
            var taxonOrder: Int?
            var category: String
            var first: Sighting?
            var last: Sighting?
            var observationCount: Int = 0
        }
        struct Sighting {
            var dateRaw: String
            var sortKey: String
            var location: String?
            var locId: String?
            var subId: String?
            var countryCode: String?
        }

        var byKey: [String: Acc] = [:]
        var rawRowCount = 0

        for line in lines.dropFirst() {
            let cols = parseCSVLine(line)
            guard let common = field(cols, commonIdx), !common.isEmpty else { continue }
            rawRowCount += 1

            let category = (field(cols, index.category) ?? "species").lowercased()
            // My Data has no Countable column — drop obvious non-species labels.
            if isNonCountableName(common) || (category != "species" && !category.isEmpty && category != "issf" && category != "form") {
                continue
            }

            let scientific = field(cols, index.scientific) ?? ""
            let key = matchKey(common: common, scientific: speciesScientificKey(scientific))
            let dateRaw = field(cols, index.date) ?? ""
            let sortKey = dateSortKey(dateRaw) ?? dateRaw
            let state = field(cols, index.stateProvince)
            let place = composedLocation(place: field(cols, index.location), state: state)
            let sighting = Sighting(
                dateRaw: dateRaw,
                sortKey: sortKey,
                location: place,
                locId: field(cols, index.locId) ?? field(cols, index.locationId),
                subId: field(cols, index.subId) ?? field(cols, index.submissionID),
                countryCode: countryCode(fromStateProvince: state) ?? countryCode(fromLocation: place)
            )

            var acc = byKey[key] ?? Acc(
                commonName: common,
                scientificName: scientific,
                taxonOrder: intField(cols, index.taxonOrder),
                category: category.isEmpty ? "species" : category
            )
            acc.observationCount += 1
            if acc.taxonOrder == nil {
                acc.taxonOrder = intField(cols, index.taxonOrder)
            }
            if let first = acc.first {
                if sortKey < first.sortKey {
                    acc.first = sighting
                }
            } else if !dateRaw.isEmpty || place != nil {
                acc.first = sighting
            }
            if let last = acc.last {
                if sortKey > last.sortKey {
                    acc.last = sighting
                }
            } else if !dateRaw.isEmpty || place != nil {
                acc.last = sighting
            }
            byKey[key] = acc
        }

        var entries: [ParsedLifeListEntry] = byKey.values.map { acc in
            ParsedLifeListEntry(
                commonName: acc.commonName,
                scientificName: acc.scientificName,
                taxonOrder: acc.taxonOrder,
                category: acc.category,
                count: nil,
                exotic: nil,
                countable: true,
                firstRecordedDate: emptyToNil(acc.first?.dateRaw),
                firstRecordedLocation: emptyToNil(acc.first?.location),
                firstLocId: acc.first?.locId,
                firstSubId: acc.first?.subId,
                firstRecordedCountryCode: emptyToNil(acc.first?.countryCode),
                lastRecordedDate: emptyToNil(acc.last?.dateRaw),
                lastRecordedLocation: emptyToNil(acc.last?.location),
                lastLocId: acc.last?.locId,
                lastSubId: acc.last?.subId,
                lastRecordedCountryCode: emptyToNil(acc.last?.countryCode)
            )
        }
        sortEntries(&entries)
        return ParsedLifeList(
            sourceFileName: sourceFileName,
            entries: entries,
            rawRowCount: rawRowCount,
            aggregatedFromMyData: true
        )
    }

    // MARK: - Columns

    private struct ColumnIndex {
        var common: Int?
        var scientific: Int?
        var taxonOrder: Int?
        var category: Int?
        var count: Int?
        var location: Int?
        var stateProvince: Int?
        var date: Int?
        var locId: Int?
        var locationId: Int?
        var subId: Int?
        var submissionID: Int?
        var exotic: Int?
        var countable: Int?
        var firstDate: Int?
        var firstLocation: Int?
        var lastDate: Int?
        var lastLocation: Int?
        var lastLocId: Int?
        var lastSubId: Int?
    }

    private static func columnIndex(_ headers: [String]) -> ColumnIndex {
        let map = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element, $0.offset) })
        func first(_ names: String...) -> Int? {
            for name in names {
                if let idx = map[name] { return idx }
            }
            return nil
        }
        return ColumnIndex(
            common: first("common name", "commonname"),
            scientific: first("scientific name", "scientificname"),
            taxonOrder: first("taxon order", "taxonomic order", "taxonorder"),
            category: first("category"),
            count: first("count"),
            location: first("location"),
            stateProvince: first("s/p", "state/province", "state province", "stateprovince"),
            date: first("date"),
            locId: first("locid", "loc id"),
            locationId: first("location id", "locationid"),
            subId: first("subid", "sub id"),
            submissionID: first("submission id", "submissionid"),
            exotic: first("exotic"),
            countable: first("countable"),
            firstDate: first("first date", "first recorded", "first recorded date", "firstdate", "date first"),
            firstLocation: first("first location", "first recorded location", "firstlocation", "location first"),
            lastDate: first("last date", "last recorded", "last recorded date", "lastdate", "date last", "most recent date"),
            lastLocation: first("last location", "last recorded location", "lastlocation", "location last", "most recent location"),
            lastLocId: first("last locid", "last loc id"),
            lastSubId: first("last subid", "last sub id")
        )
    }

    // MARK: - Helpers

    private static func resolveCountable(
        raw: String?,
        hasCountableColumn: Bool,
        category: String,
        commonName: String
    ) -> Bool {
        if let raw, !raw.isEmpty {
            let lowered = raw.lowercased()
            return raw == "1" || lowered == "true" || lowered == "yes"
        }
        if hasCountableColumn { return false }
        if isNonCountableName(commonName) { return false }
        return category == "species" || category.isEmpty || category == "issf" || category == "form"
    }

    private static func isNonCountableName(_ common: String) -> Bool {
        let lower = common.lowercased()
        if lower.contains(" sp.") || lower.hasSuffix(" sp") { return true }
        if lower.contains("/") { return true }
        if lower.contains("(hybrid)") || lower.contains(" x ") { return true }
        if lower.contains("(domestic type)") { return true }
        return false
    }

    private static func composedLocation(place: String?, state: String?) -> String? {
        let placeTrimmed = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stateTrimmed = state?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (emptyToNil(placeTrimmed), emptyToNil(stateTrimmed)) {
        case let (p?, s?):
            if p.localizedCaseInsensitiveContains(s) { return p }
            return "\(p) · \(s)"
        case let (p?, nil):
            return p
        case let (nil, s?):
            return s
        case (nil, nil):
            return nil
        }
    }

    /// eBird S/P values are `US-TX`, `CR-P`, or occasionally a bare country code.
    static func countryCode(fromStateProvince state: String?) -> String? {
        guard let state = emptyToNil(state) else { return nil }
        let head = state.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? state
        let code = head.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return nil
        }
        return code
    }

    /// Pulls a country code from a composed location (`Place · US-TX`) or a bare S/P token.
    static func countryCode(fromLocation location: String?) -> String? {
        guard let location = emptyToNil(location) else { return nil }
        let segments = location.components(separatedBy: " · ")
        for segment in segments.reversed() {
            if let code = countryCode(fromStateProvince: segment) {
                return code
            }
        }
        return countryCode(fromStateProvince: location)
    }

    private static func field(_ cols: [String], _ idx: Int?) -> String? {
        guard let idx, cols.indices.contains(idx) else { return nil }
        let value = cols[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func intField(_ cols: [String], _ idx: Int?) -> Int? {
        guard let raw = field(cols, idx) else { return nil }
        return Int(raw)
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matchKey(common: String, scientific: String) -> String {
        SpeciesCatalog.normalize(common) + "|" + SpeciesCatalog.normalize(scientific)
    }

    /// Strip subspecies epithets so My Data forms collapse to one life-list row.
    private static func speciesScientificKey(_ scientific: String) -> String {
        let parts = scientific.split(separator: " ").map(String.init)
        if parts.count >= 2 {
            return parts.prefix(2).joined(separator: " ")
        }
        return scientific
    }

    private static func sortEntries(_ entries: inout [ParsedLifeListEntry]) {
        entries.sort { lhs, rhs in
            switch (lhs.taxonOrder, rhs.taxonOrder) {
            case let (l?, r?):
                if l != r { return l < r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.commonName.localizedCaseInsensitiveCompare(rhs.commonName) == .orderedAscending
        }
    }

    /// Sortable key so earliest / latest sightings compare across common eBird date formats.
    static func dateSortKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "yyyy-MM-dd",
            "MM-dd-yyyy",
            "M-d-yyyy",
            "dd MMM yyyy",
            "d MMM yyyy",
            "MMM d, yyyy",
            "MMM dd, yyyy",
            "d-MMM-yyyy",
            "dd-MMM-yyyy",
        ]
        for format in formats {
            iso.dateFormat = format
            if let date = iso.date(from: trimmed) {
                iso.dateFormat = "yyyy-MM-dd"
                return iso.string(from: date)
            }
        }
        return trimmed
    }

    private static func normalizeHeader(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Minimal RFC-style CSV line split (quoted fields, doubled quotes).
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let ch = line[index]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }
}
