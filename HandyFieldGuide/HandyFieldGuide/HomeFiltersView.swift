import SwiftUI

/// Top home controls under the app title: value labels for Location and Month
/// (tappable pickers), with Map on the Location row and info + Settings on the Month row.
struct HomeFiltersView: View {
    @EnvironmentObject private var model: GuideModel
    /// Active place when a list is open; nil on the empty home state.
    var place: ResolvedPlace?
    var onAddLocation: () -> Void
    var onManageLocations: () -> Void
    var onMergeLists: () -> Void

    @State private var showingInfo = false
    @State private var showingSettings = false
    @Environment(\.openURL) private var openURL

    private var importedLocationOptions: [LocationOption] {
        model.imports.locations.map {
            .init(id: $0.id, title: $0.name, query: $0.name)
        }
    }

    /// Selected place name, or “Choose Location” when none is active.
    private var selectedLocationDisplayName: String {
        if let match = matchingImportedOption {
            return match.title
        }
        if importedLocationOptions.isEmpty {
            return "Choose Location"
        }
        let current = model.locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty ? "Choose Location" : current
    }

    /// Match once per body pass instead of re-normalizing in several controls.
    private var matchingImportedOption: LocationOption? {
        let current = model.locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = LocationResolver.normalize(current)
        guard !needle.isEmpty else { return nil }
        return importedLocationOptions.first {
            LocationResolver.normalize($0.query) == needle
                || LocationResolver.normalize($0.title) == needle
        }
    }

    private var showsPlaceTitleInInfo: Bool {
        guard let place else { return false }
        let title = place.coverage.placeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return LocationResolver.normalize(title) != LocationResolver.normalize(place.displayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Grid keeps Location and Month value labels the same width;
            // trailing column holds Map (row 1) and i/gear (row 2).
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow(alignment: .center) {
                    locationControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                    locationAccessory
                }
                GridRow(alignment: .center) {
                    monthControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                    monthAccessory
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(GuideColor.line)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GuideColor.paper)
        .sheet(isPresented: $showingInfo) {
            placeInfoSheet
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(model)
        }
    }

    /// Map on the Location row; empty placeholder when no place so the value column still aligns.
    @ViewBuilder
    private var locationAccessory: some View {
        if let place, let url = PlaceMaps.appleMapsURL(for: place) {
            mapButton(place: place, url: url)
                .gridCellAnchor(.trailing)
        } else {
            Color.clear
                .frame(width: 0, height: 44)
                .accessibilityHidden(true)
        }
    }

    /// Info + Settings on the Month row; trailing-aligned within the shared accessory column.
    private var monthAccessory: some View {
        HStack(spacing: 0) {
            if place != nil {
                infoButton
            }
            settingsButton
        }
        .gridCellAnchor(.trailing)
    }

    private var locationControl: some View {
        Menu {
            if !importedLocationOptions.isEmpty {
                Picker("Location", selection: locationSelection) {
                    ForEach(importedLocationOptions) { option in
                        Text(option.title).tag(option.query)
                    }
                }
                Divider()
            }
            Button {
                onManageLocations()
            } label: {
                Label("Manage locations", systemImage: "pencil")
            }
            .disabled(importedLocationOptions.isEmpty)
            Button {
                onMergeLists()
            } label: {
                Label("Merge lists", systemImage: "arrow.triangle.merge")
            }
            .disabled(importedLocationOptions.count < 2)
            Button {
                onAddLocation()
            } label: {
                Label("Add location", systemImage: "plus")
            }
        } label: {
            valueLabel(selectedLocationDisplayName)
        }
        .accessibilityLabel("Location")
        .accessibilityValue(selectedLocationDisplayName)
        .accessibilityHint("Choose an imported place, merge lists, manage saved imports, or add a location via eBird API or barchart")
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
                Button("Use device month") {
                    model.resetMonthToDevice()
                }
            }
        } label: {
            valueLabel(model.selectedMonthName)
        }
        .accessibilityLabel("Month")
        .accessibilityValue(model.selectedMonthName)
        .accessibilityHint("Imported lists use this month’s eBird frequencies")
    }

    /// Value-as-label control: shows the selected place/month, not a separate “Location”/“Month” chrome title.
    private func valueLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(GuideColor.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(GuideColor.green.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private func mapButton(place: ResolvedPlace, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label("Map", systemImage: "map")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
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

    private var infoButton: some View {
        Button {
            showingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Location details")
        .foregroundStyle(GuideColor.green)
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
        .accessibilityHint("Scarce birds, flagged taxa, and eBird API key")
        .foregroundStyle(GuideColor.green)
    }

    @ViewBuilder
    private var placeInfoSheet: some View {
        if let place {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(place.displayName)
                            .font(.system(.title2, design: .serif))
                            .foregroundStyle(GuideColor.green)
                        if showsPlaceTitleInInfo {
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

    private var locationSelection: Binding<String> {
        Binding(
            get: {
                matchingImportedOption?.query
                    ?? importedLocationOptions.first?.query
                    ?? ""
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
