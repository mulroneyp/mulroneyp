import Foundation

enum TaxonKind: String, Codable, Hashable {
    case species
    case slash
    case provisionalSp
}

struct ParsedBarchartSpecies: Hashable {
    var commonName: String
    var kind: TaxonKind
    /// Mean frequency for each calendar month (Jan = 0 … Dec = 11).
    var monthlyMean: [Double]
    /// Max week frequency within each month.
    var monthlyMax: [Double]
    /// Raw 48 week columns when present (4 weeks × 12 months).
    var weekFrequencies: [Double]
}

struct ParsedBarchart: Hashable {
    var ebirdLocationId: String?
    var sourceFileName: String
    var reportedTaxonCount: Int?
    var species: [ParsedBarchartSpecies]

    var resolvableSpeciesCount: Int {
        species.filter { $0.kind == .species }.count
    }

    var flaggedTaxonCount: Int {
        species.filter { $0.kind != .species }.count
    }
}

enum EBirdBarchartParser {
    /// Species with selected-month mean frequency below this are hidden by default.
    static let nearZeroThreshold = 0.005
    /// First-run photo / field-data enrichment targets taxa at or above this mean
    /// frequency for the selected month (plus a small top-N backup).
    static let enrichmentFrequencyThreshold = 0.05
    static let enrichmentTopCount = 40

    static func locationId(fromFileName name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[_\W])(L\d{5,})(?:[_\W]|$)"#) else {
            return nil
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return String(name[idRange])
    }

    static func parse(text: String, sourceFileName: String) throws -> ParsedBarchart {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var reported: Int?
        var rows: [ParsedBarchartSpecies] = []
        var seenSample = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let count = parseTaxonCount(trimmed) {
                reported = count
                continue
            }

            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if name == "Sample Size:" {
                seenSample = true
                continue
            }

            // Month header row has an empty first cell and Jan…Dec labels.
            if name.isEmpty && parts.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Jan" }) {
                continue
            }

            if !seenSample {
                continue
            }

            if name.isEmpty || name == "Sample Size:" { continue }

            let values = parseFrequencyValues(Array(parts.dropFirst()))
            guard values.count >= 48 else { continue }

            let weeks = Array(values.prefix(48))
            var means: [Double] = []
            var maxes: [Double] = []
            means.reserveCapacity(12)
            maxes.reserveCapacity(12)
            for month in 0..<12 {
                let slice = Array(weeks[(month * 4)..<(month * 4 + 4)])
                means.append(slice.reduce(0, +) / Double(slice.count))
                maxes.append(slice.max() ?? 0)
            }

            rows.append(
                ParsedBarchartSpecies(
                    commonName: name,
                    kind: classify(name),
                    monthlyMean: means,
                    monthlyMax: maxes,
                    weekFrequencies: weeks
                )
            )
        }

        guard !rows.isEmpty else {
            throw ParseError.empty
        }

        return ParsedBarchart(
            ebirdLocationId: locationId(fromFileName: sourceFileName),
            sourceFileName: sourceFileName,
            reportedTaxonCount: reported,
            species: rows
        )
    }

    static func parse(data: Data, sourceFileName: String) throws -> ParsedBarchart {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.encoding
        }
        return try parse(text: text, sourceFileName: sourceFileName)
    }

    static func classify(_ name: String) -> TaxonKind {
        if name.contains("/") { return .slash }
        let lowered = name.lowercased()
        if lowered.range(of: #"\bsp\.?\b"#, options: .regularExpression) != nil {
            return .provisionalSp
        }
        return .species
    }

    private static func parseTaxonCount(_ line: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"Number of taxa:\s*(\d+)"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let countRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[countRange])
    }

    private static func parseFrequencyValues(_ parts: [String]) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let value = Double(trimmed) {
                values.append(value)
            }
        }
        return values
    }

    enum ParseError: LocalizedError {
        case empty
        case encoding

        var errorDescription: String? {
            switch self {
            case .empty:
                return "No species rows were found in that eBird barchart file."
            case .encoding:
                return "That file could not be read as text."
            }
        }
    }
}
