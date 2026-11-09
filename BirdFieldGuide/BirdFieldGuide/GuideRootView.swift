import SwiftUI

struct GuideRootView: View {
    @EnvironmentObject private var model: GuideModel
    @State private var showingLocation = false
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
            .navigationTitle(model.place?.displayName ?? "Field guide")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLocation = true
                    } label: {
                        Label("Location", systemImage: "mappin.and.ellipse")
                    }
                    .accessibilityHint("Set the suburb, town, or region")
                }
            }
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
        .sheet(isPresented: $showingLocation) {
            LocationSheet(current: model.locationQuery)
        }
        .onChange(of: model.locationQuery) { _, _ in
            path = NavigationPath()
        }
    }

    private func list(guide: GuideFile, place: ResolvedPlace) -> some View {
        let birds = model.filteredSpecies(in: place)
        let filtering = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty || model.stratum != "all"
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(place.coverage.placeTitle)
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(GuideColor.muted)
                Text(place.coverage.summary)
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showingLocation = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Location")
                                .font(.caption.weight(.semibold))
                                .tracking(0.8)
                                .textCase(.uppercase)
                            Text(place.displayName)
                                .font(.title3.weight(.semibold))
                            if place.displayName != place.coverage.label {
                                Text(place.coverage.placeTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(GuideColor.muted)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .foregroundStyle(GuideColor.ink)
                    .background(GuideColor.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(GuideColor.green, lineWidth: 1.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change suburb, town, or region")

                if let notice = place.notice {
                    NoticeBox(text: notice, strong: true)
                }
                if let sample = place.coverage.sampleNote {
                    NoticeBox(text: sample, strong: false)
                }

                TextField("Search name or scientific name", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                stratumFilters(guide)

                StratumLegend(strata: guide.strata)

                Text("Showing \(birds.count) of \(place.coverage.species.count)")
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)

                if birds.isEmpty {
                    Text("No birds match. Try a scientific name, or clear the height filter.")
                        .padding(.vertical, 8)
                } else if filtering {
                    section(title: nil, birds: birds.sorted { $0.commonName < $1.commonName }, place: place)
                } else {
                    ForEach(place.groupOrder, id: \.self) { groupId in
                        let rows = birds.filter { $0.group == groupId }.sorted { $0.commonName < $1.commonName }
                        if !rows.isEmpty {
                            section(title: model.groupLabel(groupId, coverage: place.coverage), birds: rows, place: place)
                        }
                    }
                }

                Text("Height icons can be combined: a bird that feeds on a lawn and sings from a branch shows more than one. Photos are openly licensed; credits are on each bird.")
                    .font(.footnote)
                    .foregroundStyle(GuideColor.muted)
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func stratumFilters(_ guide: GuideFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HEIGHT")
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(GuideColor.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    stratumButton("Any height", id: "all")
                    ForEach(guide.strata) { item in
                        stratumButton(item.label, id: item.id)
                    }
                }
            }
        }
    }

    private func stratumButton(_ title: String, id: String) -> some View {
        Button(title) { model.stratum = id }
            .buttonStyle(GuideChipStyle(selected: model.stratum == id))
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
                    BirdRow(species: bird, place: place)
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 3) {
                ForEach(species.photos.prefix(2)) { photo in
                    BundlePhoto(path: photo.src, alt: "", fills: true)
                        .frame(width: species.photos.count > 1 ? 44 : 88, height: 64)
                        .clipped()
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
                    Text(species.status.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(species.origin == "introduced" ? GuideColor.rust : GuideColor.green)
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

    private func stratumLabel(_ id: String) -> String {
        switch id {
        case "ground": return "Ground"
        case "low": return "Low"
        case "mid": return "Mid"
        default: return "Canopy"
        }
    }
}
