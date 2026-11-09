import SwiftUI

/// Home-screen filter cluster: Location, Month, and Zone.
struct HomeFiltersView: View {
    @EnvironmentObject private var model: GuideModel
    var guide: GuideFile
    var place: ResolvedPlace
    var onAddLocation: () -> Void

    @State private var showingZoneInfo = false

    private var locationOptions: [LocationOption] {
        var options: [LocationOption] = [
            .init(id: "monteverde", title: "Children's Eternal Rainforest", query: "Monteverde"),
            .init(id: "san-gerardo", title: "San Gerardo", query: "San Gerardo"),
            .init(id: "bajo", title: "Bajo del Tigre", query: "Bajo del Tigre"),
            .init(id: "melbourne", title: "Greater Melbourne", query: "Melbourne"),
            .init(id: "bayside", title: "Bayside", query: "Bayside"),
            .init(id: "dandenong", title: "Dandenong Ranges", query: "Dandenong Ranges"),
        ]
        for imported in model.imports.locations {
            options.append(.init(id: imported.id, title: imported.name, query: imported.name))
        }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            filterBlock(title: "Location") {
                HStack(spacing: 8) {
                    Picker("Location", selection: locationSelection) {
                        ForEach(locationOptions) { option in
                            Text(option.title).tag(option.query)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        onAddLocation()
                    } label: {
                        Label("Add new", systemImage: "plus")
                    }
                    .buttonStyle(GuideChipStyle(selected: false))
                    .accessibilityHint("Import an eBird barchart file")
                }
                Text(place.coverage.placeTitle)
                    .font(.caption)
                    .foregroundStyle(GuideColor.muted)
            }

            filterBlock(title: "Month") {
                HStack {
                    Picker("Month", selection: Binding(
                        get: { model.selectedMonthIndex },
                        set: { model.setMonthIndex($0) }
                    )) {
                        ForEach(0..<12, id: \.self) { index in
                            Text(Calendar.current.monthSymbols[index]).tag(index)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer(minLength: 8)

                    if !model.isUsingDeviceMonth {
                        Button("This month") {
                            model.resetMonthToDevice()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GuideColor.green)
                    } else {
                        Text("Current calendar month")
                            .font(.caption)
                            .foregroundStyle(GuideColor.muted)
                    }
                }
                if place.imported != nil {
                    Text("Likely birds use \(model.selectedMonthName) frequencies from the imported eBird file.")
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)
                } else if place.coverage.id == "monteverde" {
                    Text("The Monteverde list is curated for mid–late November. Changing month does not rewrite that curated set.")
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)
                }
            }

            filterBlock(title: "Zone") {
                HStack(alignment: .center, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            zoneChip(title: "Any", id: "all")
                            ForEach(guide.strata) { item in
                                zoneChip(title: item.label, id: item.id)
                            }
                        }
                    }
                    Button {
                        showingZoneInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Zone descriptions")
                    .foregroundStyle(GuideColor.green)
                }
            }
        }
        .sheet(isPresented: $showingZoneInfo) {
            NavigationStack {
                List {
                    ForEach(guide.strata) { item in
                        HStack(alignment: .top, spacing: 12) {
                            StratumIcon(id: item.id, size: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label).font(.headline)
                                Text(item.hint)
                                    .font(.subheadline)
                                    .foregroundStyle(GuideColor.muted)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .guideBackground()
                .navigationTitle("Zones")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingZoneInfo = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var locationSelection: Binding<String> {
        Binding(
            get: {
                let current = model.locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty { return "Monteverde" }
                if let match = locationOptions.first(where: {
                    LocationResolver.normalize($0.query) == LocationResolver.normalize(current)
                        || LocationResolver.normalize($0.title) == LocationResolver.normalize(current)
                }) {
                    return match.query
                }
                return current
            },
            set: { model.locationQuery = $0 }
        )
    }

    private func filterBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GuideColor.card)
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(GuideColor.line, lineWidth: 1)
        }
    }

    private func zoneChip(title: String, id: String) -> some View {
        Button(title) { model.stratum = id }
            .buttonStyle(GuideChipStyle(selected: model.stratum == id))
    }
}

private struct LocationOption: Identifiable {
    var id: String
    var title: String
    var query: String
}
