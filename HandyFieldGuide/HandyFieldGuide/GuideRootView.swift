import SwiftUI

struct GuideRootView: View {
    @EnvironmentObject private var model: GuideModel
    @State private var showingAddLocation = false
    @State private var showingManageLocations = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let error = model.loadError {
                    Text(error)
                        .padding()
                } else if let guide = model.guide, let place = model.place {
                    list(guide: guide, place: place)
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
        }
        .sheet(isPresented: $showingAddLocation) {
            LocationSheet(current: model.locationQuery, startInImportMode: true)
        }
        .sheet(isPresented: $showingManageLocations) {
            LocationSheet(current: model.locationQuery, startInImportMode: false)
        }
        .onChange(of: model.locationQuery) { _, _ in
            path = NavigationPath()
        }
    }

    private func list(guide: GuideFile, place: ResolvedPlace) -> some View {
        let birds = model.filteredSpecies(in: place)
        let filtering = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty || model.isFilteringByZone
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(place.coverage.summary)
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if let notice = place.notice {
                    NoticeBox(text: notice, strong: true)
                }
                if place.imported != nil, let sample = place.coverage.sampleNote {
                    NoticeBox(text: sample, strong: false)
                }

                if place.imported != nil {
                    importedExtras
                }

                TextField("Search name or scientific name", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Showing \(birds.count) of \(place.coverage.species.count)")
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)

                if birds.isEmpty {
                    Text(place.imported == nil
                         ? "No birds match. Try a scientific name, or clear the zone filter."
                         : "No birds match for \(model.selectedMonthName). Preview another month, or show scarce birds.")
                        .padding(.vertical, 8)
                } else if filtering || place.imported != nil {
                    section(title: nil, birds: model.sortedForDisplay(birds, place: place), place: place)
                } else {
                    ForEach(place.groupOrder, id: \.self) { groupId in
                        let rows = birds.filter { $0.group == groupId }.sorted { $0.commonName < $1.commonName }
                        if !rows.isEmpty {
                            section(title: model.groupLabel(groupId, coverage: place.coverage), birds: rows, place: place)
                        }
                    }
                }

                Text(place.imported == nil
                     ? "Zone icons can be combined: a bird that feeds on a lawn and sings from a branch shows more than one. Photos are openly licensed; credits are on each bird."
                     : "Imported lists keep every taxon from the file. Near-zero \(model.selectedMonthName) rows are hidden by default (below \(Int(EBirdBarchartParser.nearZeroThreshold * 1000) / 10)% mean frequency). Flagged “sp.” and slash taxa stay off the main list unless you turn them on. Photos are openly licensed when available.")
                    .font(.footnote)
                    .foregroundStyle(GuideColor.muted)
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeFiltersView(
                guide: guide,
                place: place,
                onAddLocation: { showingAddLocation = true },
                onManageLocations: { showingManageLocations = true }
            )
        }
    }

    private var importedExtras: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Hide scarce / near-zero for \(model.selectedMonthName)", isOn: Binding(
                get: { model.hideNearZero },
                set: { model.setHideNearZero($0) }
            ))
            Toggle("Show flagged sp. / slash taxa", isOn: $model.showFlaggedTaxa)
        }
        .font(.subheadline)
    }

    private func section(title: String?, birds: [Species], place: ResolvedPlace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(GuideColor.green)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            ForEach(birds) { bird in
                NavigationLink(value: bird.id) {
                    BirdRow(
                        species: bird,
                        place: place,
                        frequency: model.frequency(for: bird, in: place)
                    )
                }
                .buttonStyle(.plain)
            }
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
    var place: ResolvedPlace
    var frequency: Double?

    private var likelihood: String {
        Likelihood.label(for: species, frequency: frequency)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 3) {
                ForEach(listPhotos) { photo in
                    BundlePhoto(path: photo.src, alt: "", fills: true)
                        .frame(width: listPhotos.count > 1 ? 44 : 88, height: 64)
                        .clipped()
                }
                if listPhotos.isEmpty {
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
        .accessibilityHint("Opens habitat notes for \(place.displayName)")
    }

    private var listPhotos: [Photo] {
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
