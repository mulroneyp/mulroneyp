import SwiftUI

/// Bottom toolbar for Location, Month, and Zone — keeps the bird list above.
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

    private var selectedLocationTitle: String {
        let current = model.locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = locationOptions.first(where: {
            LocationResolver.normalize($0.query) == LocationResolver.normalize(current)
                || LocationResolver.normalize($0.title) == LocationResolver.normalize(current)
        }) {
            return match.title
        }
        if current.isEmpty { return "Children's Eternal Rainforest" }
        return current
    }

    private var selectedZoneTitle: String {
        if model.stratum == "all" { return "Any" }
        return guide.strata.first(where: { $0.id == model.stratum })?.label ?? "Any"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                locationControl
                barDivider
                monthControl
                barDivider
                zoneControl
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(.bar)
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

    private var barDivider: some View {
        Rectangle()
            .fill(GuideColor.line)
            .frame(width: 1, height: 36)
            .padding(.vertical, 4)
    }

    private var locationControl: some View {
        Menu {
            Picker("Location", selection: locationSelection) {
                ForEach(locationOptions) { option in
                    Text(option.title).tag(option.query)
                }
            }
            Divider()
            Button {
                onAddLocation()
            } label: {
                Label("Add eBird barchart", systemImage: "plus")
            }
        } label: {
            filterColumn(title: "Location", value: selectedLocationTitle)
        }
        .accessibilityHint("Choose a place or import an eBird barchart")
    }

    private var monthControl: some View {
        Menu {
            Picker("Month", selection: Binding(
                get: { model.selectedMonthIndex },
                set: { model.setMonthIndex($0) }
            )) {
                ForEach(0..<12, id: \.self) { index in
                    Text(Calendar.current.monthSymbols[index]).tag(index)
                }
            }
            if !model.isUsingDeviceMonth {
                Divider()
                Button("This month") {
                    model.resetMonthToDevice()
                }
            }
        } label: {
            filterColumn(
                title: "Month",
                value: model.selectedMonthName,
                caption: model.isUsingDeviceMonth ? "Current" : "Preview"
            )
        }
        .accessibilityHint(
            place.imported != nil
                ? "Imported lists use this month’s eBird frequencies"
                : "Defaults to the current calendar month"
        )
    }

    private var zoneControl: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("Zone", selection: $model.stratum) {
                    Text("Any").tag("all")
                    ForEach(guide.strata) { item in
                        Text(item.label).tag(item.id)
                    }
                }
            } label: {
                filterColumn(title: "Zone", value: selectedZoneTitle)
            }
            .accessibilityHint("Filter by height band, including Sky")

            Button {
                showingZoneInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel("Zone descriptions")
            .foregroundStyle(GuideColor.green)
        }
    }

    private func filterColumn(title: String, value: String, caption: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(GuideColor.muted)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GuideColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(GuideColor.muted)
            } else {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(GuideColor.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
}

private struct LocationOption: Identifiable {
    var id: String
    var title: String
    var query: String
}
