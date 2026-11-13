import Foundation

/// Parses eBird `barchartData?fmt=json` into the same `ParsedBarchart` shape as `.txt` TSV.
enum EBirdBarchartJSONParser {
    static func parse(data: Data, locId: String, sourceFileName: String) throws -> ParsedBarchart {
        let root: JSONRoot
        do {
            root = try JSONDecoder().decode(JSONRoot.self, from: data)
        } catch {
            // Some responses wrap rows differently or return HTML — surface clearly.
            if String(data: data.prefix(200), encoding: .utf8)?.lowercased().contains("html") == true {
                throw EBirdAPIError.loginRequired
            }
            throw EBirdAPIError.decodeFailed
        }

        var rows: [ParsedBarchartSpecies] = []
        rows.reserveCapacity(root.dataRows.count)

        for row in root.dataRows {
            let name = row.resolvedCommonName
            guard !name.isEmpty else { continue }
            let values = row.values.map { max(0, $0) }
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
                    kind: EBirdBarchartParser.classify(name),
                    monthlyMean: means,
                    monthlyMax: maxes,
                    weekFrequencies: weeks
                )
            )
        }

        guard !rows.isEmpty else {
            throw EBirdAPIError.emptyFrequency
        }

        return ParsedBarchart(
            ebirdLocationId: locId,
            sourceFileName: sourceFileName,
            reportedTaxonCount: root.numSpecies ?? rows.count,
            species: rows
        )
    }

    private struct JSONRoot: Decodable {
        var numSpecies: Int?
        var dataRows: [JSONRow]

        private enum CodingKeys: String, CodingKey {
            case numSpecies
            case dataRows
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            numSpecies = try container.decodeIfPresent(Int.self, forKey: .numSpecies)
            dataRows = try container.decodeIfPresent([JSONRow].self, forKey: .dataRows) ?? []
        }
    }

    private struct JSONRow: Decodable {
        var values: [Double]
        var taxon: TaxonPayload?

        var resolvedCommonName: String {
            if let taxon {
                return taxon.commonName
            }
            return ""
        }

        private enum CodingKeys: String, CodingKey {
            case values
            case taxon
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            values = try container.decodeIfPresent([Double].self, forKey: .values) ?? []
            if let object = try? container.decode(TaxonObject.self, forKey: .taxon) {
                taxon = .object(object)
            } else if let name = try? container.decode(String.self, forKey: .taxon) {
                taxon = .name(name)
            } else {
                taxon = nil
            }
        }
    }

    private enum TaxonPayload {
        case object(TaxonObject)
        case name(String)

        var commonName: String {
            switch self {
            case .object(let object):
                return object.resolvedName
            case .name(let name):
                return name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private struct TaxonObject: Decodable {
        var commonName: String?
        var comName: String?
        var name: String?

        var resolvedName: String {
            let candidates = [commonName, comName, name]
            for candidate in candidates {
                if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmed.isEmpty {
                    return trimmed
                }
            }
            return ""
        }
    }
}
