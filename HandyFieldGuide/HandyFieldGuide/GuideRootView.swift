import SwiftUI
import UIKit

struct GuideRootView: View {
    @EnvironmentObject private var model: GuideModel
    @State private var showingAddLocation = false
    @State private var showingManageLocations = false
    @State private var path = NavigationPath()
    @FocusState private var isSearchFocused: Bool
    /// Local draft so keystrokes do not republish GuideModel / rebuild the bottom bar every character.
    @State private var searchDraft = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let error = model.loadError {
                    Text(error)
                        .padding()
                } else if let guide = model.guide {
                    if let place = model.place {
                        list(guide: guide, place: place)
                    } else {
                        emptyLocations(guide: guide)
                    }
                } else {
                    ProgressView("Loading the guide")
                }
            }
            .guideBackground()
            .navigationTitle("Handy Field Guide")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { speciesId in
                if let place = model.place,
                   let species = place.coverage.species.first(where: { $0.id == speciesId }) {
                    BirdDetailView(species: species, place: place)
                } else {
                    Text("That bird is not in this guide.")
                        .guideBackground()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissSearchKeyboard() }
                }
            }
        }
        .sheet(isPresented: $showingAddLocation) {
            LocationSheet(startInImportMode: true)
        }
        .sheet(isPresented: $showingManageLocations) {
            LocationSheet(startInImportMode: false)
        }
        .onChange(of: model.locationQuery) { _, _ in
            dismissSearchKeyboard()
            path = NavigationPath()
        }
        .onChange(of: path.count) { _, _ in
            // Selecting a result / pushing detail should hide the search keyboard.
            dismissSearchKeyboard()
        }
        .onChange(of: showingAddLocation) { _, open in
            if open { dismissSearchKeyboard() }
        }
        .onChange(of: showingManageLocations) { _, open in
            if open { dismissSearchKeyboard() }
        }
        .onAppear {
            searchDraft = model.searchText
        }
    }

    private func applySearchDraft(_ value: String, immediate: Bool) {
        searchDebounceTask?.cancel()
        if immediate {
            if model.searchText != value {
                model.searchText = value
            }
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            if model.searchText != value {
                model.searchText = value
            }
        }
    }

    private func dismissSearchKeyboard() {
        isSearchFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }

    private func emptyLocations(guide: GuideFile) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                Text("No location yet")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(GuideColor.green)
                Text(
                    model.hasImportedLocations
                        ? "Choose a saved import from Location, or add another eBird barchart. The guide only shows birds from places you import — it does not invent lists."
                        : "Add or import an eBird barchart to see birds for a place. Only imported locations appear here — there is no default checklist."
                )
                .font(.body)
                .foregroundStyle(GuideColor.ink)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    showingAddLocation = true
                } label: {
                    Label("Add eBird barchart", systemImage: "plus")
                }
                .buttonStyle(GuideChipStyle(selected: true))

                if model.hasImportedLocations {
                    Button {
                        showingManageLocations = true
                    } label: {
                        Label("Manage locations", systemImage: "pencil")
                    }
                    .buttonStyle(GuideChipStyle(selected: false))
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeFiltersView(
                guide: guide,
                onAddLocation: { showingAddLocation = true },
                onManageLocations: { showingManageLocations = true }
            )
        }
    }

    private func list(guide: GuideFile, place: ResolvedPlace) -> some View {
        let birds = model.sortedForDisplay(model.filteredSpecies(in: place), place: place)
        // LazyVStack keeps off-screen rows (and their photo tasks) from building during scroll.
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                LocationHeader(place: place)
                    .simultaneousGesture(TapGesture().onEnded(dismissSearchKeyboard))

                if let notice = place.notice {
                    NoticeBox(text: notice, strong: true)
                        .simultaneousGesture(TapGesture().onEnded(dismissSearchKeyboard))
                }

                HStack(spacing: 8) {
                    TextField("Search name or scientific name", text: $searchDraft)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            applySearchDraft(searchDraft, immediate: true)
                            dismissSearchKeyboard()
                        }
                        .onChange(of: searchDraft) { _, newValue in
                            applySearchDraft(newValue, immediate: false)
                        }

                    if !searchDraft.isEmpty {
                        Button {
                            searchDraft = ""
                            applySearchDraft("", immediate: true)
                            dismissSearchKeyboard()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(GuideColor.muted)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }

                Text("Showing \(birds.count) of \(place.coverage.species.count)")
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissSearchKeyboard)

                if birds.isEmpty {
                    Text("No birds match for \(model.selectedMonthName). Try another month, or change scarce / flagged filters in Settings.")
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissSearchKeyboard)
                } else {
                    ForEach(birds) { bird in
                        NavigationLink(value: bird.id) {
                            BirdRow(
                                species: bird,
                                placeDisplayName: place.displayName,
                                frequency: model.frequency(for: bird, in: place)
                            )
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded(dismissSearchKeyboard))
                    }
                }

                Text("Imported lists keep every taxon from the file. Near-zero \(model.selectedMonthName) rows and flagged “sp.” / slash taxa are controlled in Settings. Photos are openly licensed when available.")
                    .font(.footnote)
                    .foregroundStyle(GuideColor.muted)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissSearchKeyboard)
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeFiltersView(
                guide: guide,
                onAddLocation: { showingAddLocation = true },
                onManageLocations: { showingManageLocations = true }
            )
            // Tapping the bottom filter bar should hide the keyboard without blocking menus.
            .simultaneousGesture(TapGesture().onEnded(dismissSearchKeyboard))
        }
    }
}

/// Compact place chrome: name + Maps link + “i” for the long coverage prose.
private struct LocationHeader: View {
    var place: ResolvedPlace
    @State private var showingInfo = false
    @Environment(\.openURL) private var openURL

    private var showsPlaceTitleSubtitle: Bool {
        let title = place.coverage.placeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return LocationResolver.normalize(title) != LocationResolver.normalize(place.displayName)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.displayName)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(GuideColor.green)
                    .fixedSize(horizontal: false, vertical: true)
                if showsPlaceTitleSubtitle {
                    Text(place.coverage.placeTitle)
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = PlaceMaps.appleMapsURL(for: place) {
                Button {
                    openURL(url)
                } label: {
                    Label("Map", systemImage: "map")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(GuideColor.green.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
                        }
                }
                .foregroundStyle(GuideColor.green)
                .accessibilityLabel("Open \(place.displayName) in Maps")
                .accessibilityHint(PlaceMaps.searchQuery(for: place).map { "Searches Maps for \($0)" } ?? "")
            }

            Button {
                showingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel("Location details")
            .foregroundStyle(GuideColor.green)
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(place.displayName)
                            .font(.system(.title2, design: .serif))
                            .foregroundStyle(GuideColor.green)
                        if showsPlaceTitleSubtitle {
                            Text(place.coverage.placeTitle)
                                .font(.subheadline)
                                .foregroundStyle(GuideColor.muted)
                        }
                        Text(place.coverage.summary)
                            .font(.body)
                            .foregroundStyle(GuideColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let lead = place.district?.lead.trimmingCharacters(in: .whitespacesAndNewlines),
                           !lead.isEmpty {
                            Text(lead)
                                .font(.body)
                                .foregroundStyle(GuideColor.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let sample = place.coverage.sampleNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !sample.isEmpty {
                            Text(sample)
                                .font(.subheadline)
                                .foregroundStyle(GuideColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .guideBackground()
                .navigationTitle("About this place")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingInfo = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct NoticeBox: View {
    var text: String
    var strong: Bool

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(GuideColor.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(strong ? GuideColor.rust.opacity(0.12) : GuideColor.green.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(strong ? GuideColor.rust : GuideColor.green.opacity(0.35), lineWidth: 1)
            }
    }
}

private struct BirdRow: View {
    var species: Species
    var placeDisplayName: String
    var frequency: Double?

    /// Longest edge for list thumbnails (~88pt × 3x). Far smaller than full 900–1000px JPEGs.
    private static let listThumbMaxPixels: CGFloat = 270

    var body: some View {
        let photos = Self.listPhotos(for: species)
        let likelihood = Likelihood.label(for: species, frequency: frequency)
        return HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 3) {
                ForEach(photos) { photo in
                    BundlePhoto(
                        path: photo.src,
                        alt: "",
                        fills: true,
                        maxPixelSize: Self.listThumbMaxPixels
                    )
                    .frame(width: photos.count > 1 ? 44 : 88, height: 64)
                    .clipped()
                }
                if photos.isEmpty {
                    GuideColor.green.opacity(0.12)
                        .frame(width: 88, height: 64)
                }
            }
            .frame(width: 92, height: 64, alignment: .leading)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(species.commonName)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(GuideColor.ink)
                Text(species.scientificName)
                    .font(.subheadline.italic())
                    .foregroundStyle(GuideColor.muted)
                Text(species.summary)
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(likelihood.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(species.origin == "introduced" ? GuideColor.rust : GuideColor.green)
                    if let frequency, frequency > 0 {
                        Text(frequencyLabel(frequency))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(GuideColor.muted)
                    }
                    Text(ActiveTime.rowLabel(for: species))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(GuideColor.muted)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    ForEach(species.strata, id: \.self) { id in
                        HStack(spacing: 2) {
                            StratumIcon(id: id, size: 18)
                            Text(stratumLabel(id))
                                .font(.caption2)
                                .foregroundStyle(GuideColor.green)
                        }
                        .accessibilityLabel(stratumLabel(id))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GuideColor.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens habitat notes for \(placeDisplayName)")
    }

    private static func listPhotos(for species: Species) -> [Photo] {
        let order = ["male": 0, "female": 1, "either": 2, "unsexed": 3, "illustration": 4]
        let sorted = species.photos.sorted {
            (order[$0.role] ?? 9, $0.label) < (order[$1.role] ?? 9, $1.label)
        }
        if species.dimorphic {
            let sexes = sorted.filter { $0.role == "male" || $0.role == "female" }
            if sexes.count >= 2 { return Array(sexes.prefix(2)) }
            return Array(sorted.prefix(2))
        }
        return Array(sorted.prefix(1))
    }

    private func frequencyLabel(_ value: Double) -> String {
        if value < 0.01 { return "<1%" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func stratumLabel(_ id: String) -> String {
        switch id {
        case "ground": return "Ground"
        case "low": return "Low"
        case "mid": return "Mid"
        case "canopy": return "Canopy"
        case "sky": return "Sky"
        default: return id.capitalized
        }
    }
}
