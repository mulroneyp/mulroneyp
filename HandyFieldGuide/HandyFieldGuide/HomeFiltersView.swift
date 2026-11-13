import SwiftUI

/// Bottom toolbar for Location, Month, Zone, and Settings — keeps the bird list above.
struct HomeFiltersView: View {
    @EnvironmentObject private var model: GuideModel
    var guide: GuideFile
    var onAddLocation: () -> Void
    var onManageLocations: () -> Void
    var onMergeLists: () -> Void

    @State private var showingZoneInfo = false
    @State private var showingSettings = false

    private var importedLocationOptions: [LocationOption] {
        model.imports.locations.map {
            .init(id: $0.id, title: $0.name, query: $0.name)
        }
    }

    /// For VoiceOver only — the bar label stays generic “Location”.
    private var selectedLocationAccessibilityValue: String {
        if let match = matchingImportedOption {
            return match.title
        }
        if importedLocationOptions.isEmpty {
            return "No location yet"
        }
        let current = model.locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty ? "No location selected" : current
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

    private var selectedZoneTitle: String {
        let selected = guide.strata.filter { model.selectedStrata.contains($0.id) }
        switch selected.count {
        case 0:
            return "Any"
        case 1:
            return selected[0].label
        case 2:
            return "\(selected[0].label) + \(selected[1].label)"
        default:
            return "\(selected.count) zones"
        }
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
                barDivider
                settingsControl
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 6)
            // On iPad the sidebar can be wide; keep the four controls clustered rather than stretched.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        // safeAreaInset proposes the full container height. Without fixedSize, this
        // VStack expands to that proposal: layout still uses the ideal bar height, but
        // hit-testing covers the bird list (and can block detail after push). Keep the
        // material only on the bar + home indicator, not a full-screen layer.
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(model)
        }
    }

    private var barDivider: some View {
        // Capsule + fixed frame avoids a greedy Shape stretching with the HStack proposal.
        Capsule()
            .fill(GuideColor.line)
            .frame(width: 1, height: 36)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
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
            filterIconColumn(title: "Location", systemImage: "mappin.and.ellipse")
        }
        .accessibilityLabel("Location")
        .accessibilityValue(selectedLocationAccessibilityValue)
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
            filterColumn(title: "Month", value: model.selectedMonthName)
        }
        .accessibilityHint("Imported lists use this month’s eBird frequencies")
    }

    private var zoneControl: some View {
        HStack(spacing: 0) {
            Menu {
                Button {
                    model.clearStrata()
                } label: {
                    if model.selectedStrata.isEmpty {
                        Label("Any", systemImage: "checkmark")
                    } else {
                        Text("Any")
                    }
                }
                ForEach(guide.strata) { item in
                    Button {
                        model.toggleStratum(item.id)
                    } label: {
                        if model.selectedStrata.contains(item.id) {
                            Label(item.label, systemImage: "checkmark")
                        } else {
                            Text(item.label)
                        }
                    }
                }
            } label: {
                filterColumn(title: "Zone", value: selectedZoneTitle)
            }
            .menuActionDismissBehavior(.disabled)
            .accessibilityHint("Select one or more habitat zones, including Sky. Any clears the filter.")

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

    private var settingsControl: some View {
        Button {
            showingSettings = true
        } label: {
            VStack(spacing: 2) {
                Text("SETTINGS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(GuideColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GuideColor.ink)
                    .frame(height: 20)
                // Match the chevron row height of other columns so the bar stays level.
                Color.clear
                    .frame(height: 11)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityHint("Scarce birds and flagged taxa filters")
    }

    private func filterColumn(title: String, value: String) -> some View {
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
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(GuideColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Generic Location (or similar) column — no place name in the bar.
    private func filterIconColumn(title: String, systemImage: String) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(GuideColor.muted)
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GuideColor.ink)
                .frame(height: 20)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(GuideColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
