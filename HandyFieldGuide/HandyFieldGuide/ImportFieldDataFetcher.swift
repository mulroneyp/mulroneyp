import Foundation

/// Batch Wikipedia lookup to fill blank appearance/ID lines and published lengths
/// on the current birdlist. Already-filled curated text is left alone.
@MainActor
final class ImportFieldDataFetcher: ObservableObject, Identifiable {
    let id = UUID()

    enum Phase: Equatable {
        case idle
        case running
        case cancelled
        case finished
    }

    struct WorkItem: Identifiable, Hashable {
        var id: String { speciesId }
        var speciesId: String
        var commonName: String
        var scientificName: String
        var needSummary: Bool
        var needLength: Bool
        var frequency: Double
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var completed: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var filledSummaryCount: Int = 0
    @Published private(set) var filledLengthCount: Int = 0
    @Published private(set) var skippedCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    @Published private(set) var currentName: String = ""
    @Published private(set) var estimatedSecondsRemaining: TimeInterval?
    @Published private(set) var statusMessage: String = ""

    var isActive: Bool { phase == .running }
    var fractionComplete: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    private let fieldCache: SpeciesFieldCacheStore
    private let client: WikipediaFieldClient
    private let scientificResolver: CommonsPhotoClient
    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var durations: [TimeInterval] = []

    init(
        fieldCache: SpeciesFieldCacheStore,
        client: WikipediaFieldClient = .shared,
        scientificResolver: CommonsPhotoClient = .shared
    ) {
        self.fieldCache = fieldCache
        self.client = client
        self.scientificResolver = scientificResolver
    }

    func cancel() {
        guard phase == .running else { return }
        task?.cancel()
        phase = .cancelled
        statusMessage = "Stopped. Descriptions and sizes already saved stay on this device."
        estimatedSecondsRemaining = nil
    }

    func dismissFinished() {
        if phase == .finished || phase == .cancelled {
            phase = .idle
        }
    }

    /// Species in this import that still lack a usable appearance line and/or length.
    static func workItems(
        for record: ImportedLocationRecord,
        catalog: SpeciesCatalog,
        fieldCache: SpeciesFieldCacheStore,
        monthIndex: Int
    ) -> [WorkItem] {
        var items: [WorkItem] = []
        for taxon in record.species where taxon.kind == .species {
            var species = catalog.resolvedSpecies(
                for: taxon,
                locationLabel: record.name,
                monthIndex: monthIndex
            )
            // Apply cache before deciding gaps so we do not re-fetch across locations.
            fieldCache.applyCachedFields(to: &species)

            let needSummary = !SpeciesDescription.hasText(for: species)
            let needLength = !BirdSize.hasLength(species)
                && !WikipediaFieldClient.shouldSkipLength(
                    commonName: species.commonName,
                    speciesId: species.id
                )
            guard needSummary || needLength else { continue }

            items.append(
                WorkItem(
                    speciesId: species.id,
                    commonName: species.commonName,
                    scientificName: species.scientificName,
                    needSummary: needSummary,
                    needLength: needLength,
                    frequency: taxon.mean(monthIndex: monthIndex)
                )
            )
        }
        return items.sorted {
            if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
            return $0.commonName < $1.commonName
        }
    }

    func start(items: [WorkItem]) {
        task?.cancel()
        completed = 0
        filledSummaryCount = 0
        filledLengthCount = 0
        skippedCount = 0
        failedCount = 0
        total = items.count
        estimatedSecondsRemaining = nil
        durations = []
        currentName = ""
        guard !items.isEmpty else {
            phase = .finished
            statusMessage = "Every species on this list already has a description and size when known."
            return
        }
        phase = .running
        statusMessage = "Looking up descriptions and sizes…"
        startedAt = Date()
        task = Task { [weak self] in
            await self?.run(items: items)
        }
    }

    private func run(items: [WorkItem]) async {
        for item in items {
            if Task.isCancelled {
                phase = .cancelled
                statusMessage = "Stopped. Descriptions and sizes already saved stay on this device."
                estimatedSecondsRemaining = nil
                return
            }
            currentName = item.commonName
            let stepStart = Date()
            do {
                let filled = try await fetchOne(item)
                if filled.summary || filled.length {
                    if filled.summary { filledSummaryCount += 1 }
                    if filled.length { filledLengthCount += 1 }
                } else {
                    skippedCount += 1
                }
            } catch is CancellationError {
                phase = .cancelled
                statusMessage = "Stopped. Descriptions and sizes already saved stay on this device."
                estimatedSecondsRemaining = nil
                return
            } catch {
                failedCount += 1
            }
            completed += 1
            let elapsed = Date().timeIntervalSince(stepStart)
            durations.append(elapsed)
            updateETA()
        }
        phase = .finished
        estimatedSecondsRemaining = 0
        currentName = ""
        statusMessage = summaryMessage()
    }

    private struct FillResult {
        var summary: Bool
        var length: Bool
    }

    private func fetchOne(_ item: WorkItem) async throws -> FillResult {
        try Task.checkCancellation()

        var scientific = item.scientificName
        if scientific == "—" || scientific.isEmpty || scientific == "-" {
            scientific = await scientificResolver.resolveScientificName(
                commonName: item.commonName,
                hinted: item.scientificName
            )
        }

        let result = try await client.lookup(
            commonName: item.commonName,
            scientificName: scientific,
            needSummary: item.needSummary,
            needLength: item.needLength
        )

        let summaryToSave: String? = item.needSummary && !result.summary.isEmpty ? result.summary : nil
        let lengthToSave: [Double]? = item.needLength && !result.lengthCm.isEmpty ? result.lengthCm : nil
        let scientificToSave = !result.scientificName.isEmpty
            ? result.scientificName
            : (scientific.isEmpty ? nil : scientific)

        guard summaryToSave != nil || lengthToSave != nil || scientificToSave != nil else {
            return FillResult(summary: false, length: false)
        }

        // Only persist when we actually filled a requested blank (or resolved a binomial).
        if summaryToSave != nil || lengthToSave != nil {
            fieldCache.saveFields(
                speciesId: item.speciesId,
                commonName: item.commonName,
                scientificName: scientificToSave,
                summary: summaryToSave,
                lengthCm: lengthToSave
            )
            return FillResult(summary: summaryToSave != nil, length: lengthToSave != nil)
        }

        // Binomial alone is useful for later lookups / display of stubs.
        fieldCache.saveFields(
            speciesId: item.speciesId,
            commonName: item.commonName,
            scientificName: scientificToSave,
            summary: nil,
            lengthCm: nil
        )
        return FillResult(summary: false, length: false)
    }

    private func updateETA() {
        let remaining = total - completed
        guard remaining > 0 else {
            estimatedSecondsRemaining = 0
            return
        }
        let window = durations.suffix(8)
        guard !window.isEmpty else {
            estimatedSecondsRemaining = nil
            return
        }
        let avg = window.reduce(0, +) / Double(window.count)
        estimatedSecondsRemaining = avg * Double(remaining)
    }

    private func summaryMessage() -> String {
        var parts: [String] = []
        if filledSummaryCount > 0 {
            parts.append(
                "Filled \(filledSummaryCount) description\(filledSummaryCount == 1 ? "" : "s")"
            )
        }
        if filledLengthCount > 0 {
            parts.append(
                "Filled \(filledLengthCount) size\(filledLengthCount == 1 ? "" : "s")"
            )
        }
        if skippedCount > 0 {
            parts.append("\(skippedCount) without a published match")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) network miss\(failedCount == 1 ? "" : "es")")
        }
        if parts.isEmpty {
            return "No new descriptions or sizes found."
        }
        return parts.joined(separator: " · ") + "."
    }

    static func formatETA(_ seconds: TimeInterval?) -> String {
        ImportPhotoFetcher.formatETA(seconds)
    }
}
