import Foundation

enum LocationResolver {
    static func resolve(query raw: String, guide: GuideFile) -> ResolvedPlace {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = guide.coverages.first { $0.id == guide.defaultCoverageId } ?? guide.coverages[0]
        let home = fallback.districts.first { $0.id == "all" }
        if normalize(trimmed).isEmpty {
            return ResolvedPlace(
                query: "",
                coverage: fallback,
                district: home,
                displayName: fallback.label,
                isOutside: false,
                notice: nil
            )
        }

        let districtHit = bestDistrict(in: trimmed, guide: guide)
        let outsideHit = bestOutside(in: trimmed, guide: guide)
        if let districtHit, let outsideHit {
            if outsideHit.alias.count > districtHit.alias.count {
                return outsidePlace(outsideHit, typed: trimmed, guide: guide)
            }
            return inside(districtHit, typed: trimmed)
        }
        if let districtHit {
            return inside(districtHit, typed: trimmed)
        }
        if let outsideHit {
            return outsidePlace(outsideHit, typed: trimmed, guide: guide)
        }
        if let hinted = realmHint(trimmed, guide: guide, fallback: fallback) {
            return hinted
        }
        return ResolvedPlace(
            query: trimmed,
            coverage: fallback,
            district: home,
            displayName: fallback.label,
            isOutside: true,
            notice: "No curated list for \(trimmed). This guide doesn’t recognise that place, so it is showing \(fallback.label), the default coverage, rather than inventing birds."
        )
    }

    private struct DistrictHit {
        var coverage: Coverage
        var district: District
        var alias: String
    }

    private struct OutsideHit {
        var place: OutsidePlace
        var alias: String
    }

    private static func bestDistrict(in query: String, guide: GuideFile) -> DistrictHit? {
        var best: DistrictHit?
        for coverage in guide.coverages {
            for district in coverage.districts where district.id != "all" {
                guard let alias = longestAlias(in: query, aliases: district.aliases) else { continue }
                if best == nil || alias.count > best!.alias.count {
                    best = DistrictHit(coverage: coverage, district: district, alias: alias)
                }
            }
            if let all = coverage.districts.first(where: { $0.id == "all" }),
               let alias = longestAlias(in: query, aliases: all.aliases + coverage.aliases) {
                if best == nil || alias.count > best!.alias.count {
                    best = DistrictHit(coverage: coverage, district: all, alias: alias)
                }
            }
        }
        return best
    }

    private static func bestOutside(in query: String, guide: GuideFile) -> OutsideHit? {
        var best: OutsideHit?
        for place in guide.outside {
            guard let alias = longestAlias(in: query, aliases: place.names) else { continue }
            if best == nil || alias.count > best!.alias.count {
                best = OutsideHit(place: place, alias: alias)
            }
        }
        return best
    }

    private static func longestAlias(in query: String, aliases: [String]) -> String? {
        let padded = " \(normalize(query)) "
        return aliases
            .map(normalize)
            .filter { !$0.isEmpty && padded.contains(" \($0) ") }
            .max { $0.count < $1.count }
    }

    private static func inside(_ hit: DistrictHit, typed: String) -> ResolvedPlace {
        let specific = hit.district.id != "all"
        let name = specific ? titleCase(typed) : hit.coverage.label
        return ResolvedPlace(
            query: typed,
            coverage: hit.coverage,
            district: hit.district,
            displayName: name,
            isOutside: false,
            notice: nil
        )
    }

    private static func outsidePlace(_ hit: OutsideHit, typed: String, guide: GuideFile) -> ResolvedPlace {
        let coverage = guide.coverages.first { $0.id == hit.place.closestCoverageId }
            ?? guide.coverages[0]
        let district = coverage.districts.first { $0.id == "all" }
        return ResolvedPlace(
            query: typed,
            coverage: coverage,
            district: district,
            displayName: coverage.label,
            isOutside: true,
            notice: "No curated list for \(typed). \(hit.place.because) Showing \(coverage.label), the closest coverage in this guide, not birds invented for \(typed)."
        )
    }

    private static func realmHint(_ query: String, guide: GuideFile, fallback: Coverage) -> ResolvedPlace? {
        let text = normalize(query)
        let words = Set(text.split(separator: " ").map(String.init))
        let oceaniaWords: Set<String> = ["australia", "australian", "victoria", "nsw", "queensland", "tasmania", "tasmanian"]
        let oceaniaPhrases = ["new south wales", "south australia", "western australia", "northern territory"]
        let americasWords: Set<String> = ["nicaragua", "panama", "caribbean", "honduras", "guatemala"]
        let closestId: String?
        let because: String?
        let mentionsOceania = !words.isDisjoint(with: oceaniaWords) || oceaniaPhrases.contains { text.contains($0) }
        let mentionsAmericas = text.contains("costa rica") || text.contains("central america") || !words.isDisjoint(with: americasWords)
        if mentionsOceania && !mentionsAmericas {
            closestId = "greater-melbourne"
            because = "It is outside the greater Melbourne set curated for this guide."
        } else if mentionsAmericas {
            closestId = "monteverde"
            because = "The curated Central America list is the Children's Eternal Rainforest checklist, not this place."
        } else {
            closestId = nil
            because = nil
        }
        guard let closestId, let because else { return nil }
        let coverage = guide.coverages.first { $0.id == closestId } ?? fallback
        return ResolvedPlace(
            query: query,
            coverage: coverage,
            district: coverage.districts.first { $0.id == "all" },
            displayName: coverage.label,
            isOutside: true,
            notice: "No curated list for \(query). \(because) Showing \(coverage.label), the closest coverage in this guide, not birds invented for \(query)."
        )
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func titleCase(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).map { word in
            let text = String(word)
            if normalize(text) == "cbd" { return "CBD" }
            if normalize(text) == "st" { return "St" }
            return text.prefix(1).uppercased() + text.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

extension ResolvedPlace {
    func habitat(for species: Species) -> String {
        // Imported lists must never keep bundled place claims (e.g. Children's
        // Eternal Rainforest) when the active location is somewhere else.
        if imported != nil {
            return HabitatCopy.forActiveLocation(displayName, curatedHabitat: species.habitat)
        }
        guard !isOutside, let district, district.id != "all" else {
            return species.habitat
        }
        let local = district.groupNotes[species.group] ?? district.lead
        let place = displayName
        if local.isEmpty {
            return "Around \(place). \(species.habitat)"
        }
        return "Around \(place). \(local)\n\nIn the wider \(coverage.label) notes: \(species.habitat)"
    }

    var groupOrder: [String] {
        if let district, !district.groupOrder.isEmpty {
            return district.groupOrder
        }
        return coverage.groups.map(\.id)
    }
}

/// Rewrites curated habitat copy so detail screens claim the active list, not a
/// bundled Monteverde / Melbourne place the species was first authored for.
enum HabitatCopy {
    /// Leads that name a specific list or a generic import placeholder.
    private static let placeClaimLeads: [String] = [
        "Children's Eternal Rainforest, on the San Gerardo list for mid-late November.",
        "Children's Eternal Rainforest.",
        "Seen on complete checklists for the imported eBird location.",
    ]

    /// Place-name phrases that must not appear under a different active location.
    private static let foreignPlacePhrases: [String] = [
        "Children's Eternal Rainforest",
        "San Gerardo",
        "Bosque Eterno",
        "Monteverde",
        "Greater Melbourne",
        "Albert Park",
        "Royal Botanic Gardens",
        "Port Phillip",
        "Yarra",
        "Maribyrnong",
    ]

    /// Sentences that prompt curation or describe import plumbing — not field notes.
    private static let placeholderSentenceNeedles: [String] = [
        "curate a better habitat",
        "field notes are limited",
        "look it up by the common name",
        "field notes are a short placeholder",
        "until this species is curated",
    ]

    static func forActiveLocation(
        _ locationName: String,
        curatedHabitat: String,
        sourcePlaceLabels: [String] = []
    ) -> String {
        let rawPlace = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never surface an import filename / path as the place claim in bird detail.
        let place = looksLikeImportFileName(rawPlace) ? "" : rawPlace
        var remainder = curatedHabitat.trimmingCharacters(in: .whitespacesAndNewlines)

        for lead in placeClaimLeads {
            if let stripped = strippingCaseInsensitivePrefix(remainder, lead) {
                remainder = stripped
            }
        }

        if remainder.lowercased().hasPrefix("imported from the ebird frequency export for") {
            remainder = dropFirstSentence(remainder)
        }

        for label in sourcePlaceLabels {
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty else { continue }
            if !place.isEmpty,
               LocationResolver.normalize(trimmedLabel) == LocationResolver.normalize(place) {
                continue
            }
            if let first = firstSentence(remainder),
               LocationResolver.normalize(first).contains(LocationResolver.normalize(trimmedLabel)) {
                remainder = dropFirstSentence(remainder)
            }
        }

        remainder = droppingForeignPlaceSentences(remainder, activeLocation: place)
        remainder = droppingPlaceholderAndFileSentences(remainder, activeLocation: place)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        remainder = rewritingHeightBandWording(remainder)

        // Useful microhabitat only — no orphan place/filename when notes are gone.
        if remainder.isEmpty {
            return ""
        }
        if place.isEmpty {
            return remainder
        }
        if LocationResolver.normalize(remainder).hasPrefix(LocationResolver.normalize(place)) {
            return remainder
        }
        return "\(place). \(remainder)"
    }

    /// eBird barchart export names / paths must not appear in “Where you find it”.
    static func looksLikeImportFileName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.hasSuffix(".txt") || lower.hasSuffix(".csv") || lower.hasSuffix(".tsv") {
            return true
        }
        if lower.contains("barchart") { return true }
        if trimmed.contains("/") || trimmed.contains("\\") { return true }
        return false
    }

    private static func droppingPlaceholderAndFileSentences(
        _ text: String,
        activeLocation: String
    ) -> String {
        let active = LocationResolver.normalize(activeLocation)
        let kept = splitSentences(text).filter { sentence in
            let normalized = sentence.lowercased()
            for needle in placeholderSentenceNeedles {
                if normalized.contains(needle) { return false }
            }
            if normalized.hasPrefix("imported from ") { return false }
            let bare = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            if looksLikeImportFileName(bare) { return false }
            // Drop sentences that only name the active list file / path.
            if !active.isEmpty,
               looksLikeImportFileName(activeLocation),
               LocationResolver.normalize(sentence).contains(active) {
                return false
            }
            return true
        }
        return kept.joined(separator: " ")
    }

    private static func rewritingHeightBandWording(_ text: String) -> String {
        var result = text
        let replacements = [
            ("Typical height band estimated as", "Typical habitat zone estimated as"),
            ("Estimated height band:", "Estimated habitat zone:"),
            ("height band not curated", "habitat zone not curated"),
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to, options: [.caseInsensitive])
        }
        return result
    }

    private static func droppingForeignPlaceSentences(_ text: String, activeLocation: String) -> String {
        let active = LocationResolver.normalize(activeLocation)
        let sentences = splitSentences(text)
        let kept = sentences.filter { sentence in
            let normalized = LocationResolver.normalize(sentence)
            for phrase in foreignPlacePhrases {
                let needle = LocationResolver.normalize(phrase)
                guard !needle.isEmpty, normalized.contains(needle) else { continue }
                // Keep the sentence only if the active location itself mentions that place.
                if active.contains(needle) { continue }
                return false
            }
            return true
        }
        return kept.joined(separator: " ")
    }

    private static func strippingCaseInsensitivePrefix(_ text: String, _ prefix: String) -> String? {
        guard text.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(text.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstSentence(_ text: String) -> String? {
        splitSentences(text).first
    }

    private static func dropFirstSentence(_ text: String) -> String {
        let parts = splitSentences(text)
        guard parts.count > 1 else { return "" }
        return parts.dropFirst().joined(separator: " ")
    }

    private static func splitSentences(_ text: String) -> [String] {
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
}
