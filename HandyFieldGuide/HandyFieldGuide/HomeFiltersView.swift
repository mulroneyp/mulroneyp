import SwiftUI

/// Top home controls under the app title: Location, Month, and a Settings gear.
struct HomeFiltersView: View {
    @EnvironmentObject private var model: GuideModel
    var onAddLocation: () -> Void
    var onManageLocations: () -> Void
    var onMergeLists: () -> Void

    @State private var showingSettings = false

    private var importedLocationOptions: [LocationOption] {
        model.imports.locations.map {
            .init(id: $0.id, title: $0.name, query: $0.name)
        }
    }

    /// For VoiceOver only — the control label stays generic “Location”.
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                locationControl
                controlDivider
                monthControl
                controlDivider
                settingsControl
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 8)
            // On iPad the sidebar can be wide; keep the controls clustered rather than stretched.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(GuideColor.line)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GuideColor.paper)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(model)
        }
    }

    private var controlDivider: some View {
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

    private var settingsControl: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.body.weight(.semibold))
                .foregroundStyle(GuideColor.green)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityHint("Scarce birds, flagged taxa, and eBird API key")
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

    /// Generic Location column — no place name in the control.
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
