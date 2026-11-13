import SwiftUI

/// Search eBird hotspots by name / region and import frequency data over the network.
struct EBirdAPIImportSheet: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss

    /// Optional hook so Add location can dismiss after a successful API import.
    var onImported: (() -> Void)? = nil

    @State private var query = ""
    @State private var results: [EBirdHotspot] = []
    @State private var selectedPrimary: EBirdHotspot?
    @State private var nearby: [EBirdHotspot] = []
    @State private var selectedNearbyIds: Set<String> = []
    @State private var customName = ""
    @State private var isSearching = false
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var hasAPIKey: Bool { EBirdAPIKeyStore.hasKey }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        "Search hotspots by name, region code (CR, US-CA), or L-code. Frequency prefers eBird’s bar-chart histogram (48 weekly columns), with an API species-list fallback if the website blocks the download. Nearby hotspots can be merged using the maximum rate per species — never summed."
                    )
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                    if !hasAPIKey {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Add your free eBird API key in Settings before searching.")
                                .font(.footnote)
                                .foregroundStyle(GuideColor.rust)
                            Text("Get a key at ebird.org/api/keygen, then paste it under Settings → eBird API.")
                                .font(.footnote)
                                .foregroundStyle(GuideColor.muted)
                        }
                    }

                    searchField

                    if isSearching {
                        ProgressView("Searching eBird…")
                            .tint(GuideColor.green)
                    }

                    if let selectedPrimary {
                        selectionSection(primary: selectedPrimary)
                    } else if !results.isEmpty {
                        resultsSection
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(GuideColor.rust)
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(GuideColor.green)
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .guideBackground()
            .navigationTitle("Import from eBird")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isImporting)
                }
            }
            .interactiveDismissDisabled(isImporting)
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SEARCH")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            HStack(spacing: 8) {
                TextField("Hotspot, region, or L436229", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSearch() } }
                    .disabled(!hasAPIKey || isImporting)

                Button("Search") {
                    Task { await runSearch() }
                }
                .buttonStyle(GuideChipStyle(selected: true))
                .disabled(!hasAPIKey || isSearching || isImporting
                          || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOTSPOTS")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            ForEach(results.prefix(40)) { hotspot in
                Button {
                    Task { await selectPrimary(hotspot) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hotspot.locName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(GuideColor.ink)
                        Text(hotspot.subtitle)
                            .font(.caption)
                            .foregroundStyle(GuideColor.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(GuideColor.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(GuideColor.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isImporting)
            }
        }
    }

    private func selectionSection(primary: EBirdHotspot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SELECTED")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            VStack(alignment: .leading, spacing: 4) {
                Text(primary.locName)
                    .font(.body.weight(.semibold))
                Text(primary.subtitle)
                    .font(.caption)
                    .foregroundStyle(GuideColor.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GuideColor.card)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(GuideColor.green.opacity(0.5), lineWidth: 1)
            }

            Button("Choose a different hotspot") {
                selectedPrimary = nil
                nearby = []
                selectedNearbyIds = []
                customName = ""
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(GuideColor.green)
            .disabled(isImporting)

            TextField("List name (optional)", text: $customName)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .disabled(isImporting)

            if !nearby.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEARBY (OPTIONAL MERGE)")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(GuideColor.muted)
                    Text("Checked hotspots merge with the selected one using max frequency per species.")
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)

                    ForEach(nearby.prefix(15)) { hotspot in
                        Toggle(isOn: Binding(
                            get: { selectedNearbyIds.contains(hotspot.locId) },
                            set: { on in
                                if on {
                                    selectedNearbyIds.insert(hotspot.locId)
                                } else {
                                    selectedNearbyIds.remove(hotspot.locId)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hotspot.locName)
                                    .font(.subheadline.weight(.semibold))
                                Text(hotspot.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(GuideColor.muted)
                            }
                        }
                        .tint(GuideColor.green)
                        .disabled(isImporting)
                    }
                }
            }

            Button {
                Task { await runImport(primary: primary) }
            } label: {
                if isImporting {
                    Label("Importing…", systemImage: "arrow.down.circle")
                } else if selectedNearbyIds.isEmpty {
                    Label("Import hotspot", systemImage: "square.and.arrow.down")
                } else {
                    Label("Import & merge \(selectedNearbyIds.count + 1) hotspots", systemImage: "arrow.triangle.merge")
                }
            }
            .buttonStyle(GuideChipStyle(selected: true))
            .disabled(isImporting)
        }
    }

    // MARK: - Actions

    @MainActor
    private func runSearch() async {
        errorMessage = nil
        statusMessage = nil
        selectedPrimary = nil
        nearby = []
        selectedNearbyIds = []
        results = []

        guard let apiKey = EBirdAPIKeyStore.load() else {
            errorMessage = EBirdAPIError.missingAPIKey.localizedDescription
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        defer { isSearching = false }

        do {
            let found = try await EBirdAPIClient.shared.searchHotspots(
                query: trimmed,
                apiKey: apiKey
            )
            results = found
            if found.isEmpty {
                errorMessage = "No hotspots matched “\(trimmed)”. Try a region name, a clearer hotspot title, or an L-code."
            } else {
                statusMessage = "\(found.count) hotspot\(found.count == 1 ? "" : "s") found."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func selectPrimary(_ hotspot: EBirdHotspot) async {
        errorMessage = nil
        statusMessage = nil
        selectedPrimary = hotspot
        customName = hotspot.locName
        selectedNearbyIds = []
        nearby = []

        guard let apiKey = EBirdAPIKeyStore.load(),
              let lat = hotspot.lat,
              let lng = hotspot.lng else {
            return
        }

        do {
            nearby = try await EBirdAPIClient.shared.nearbyHotspots(
                latitude: lat,
                longitude: lng,
                distanceKm: 10,
                excluding: hotspot.locId,
                apiKey: apiKey
            )
        } catch {
            // Nearby is optional — keep the primary selection usable.
            nearby = []
        }
    }

    @MainActor
    private func runImport(primary: EBirdHotspot) async {
        errorMessage = nil
        statusMessage = nil
        isImporting = true
        defer { isImporting = false }

        var hotspots = [primary]
        for id in selectedNearbyIds {
            if let match = nearby.first(where: { $0.locId == id }) {
                hotspots.append(match)
            }
        }

        do {
            _ = try await model.importEBirdHotspots(
                hotspots,
                displayName: customName
            )
            onImported?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
