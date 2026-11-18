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

    /// Same reserved width on both rows for Map vs i+gear so the value pills match exactly.
    /// Wide enough for icon + the word “Map” (never icon-only) and for two 36pt icon buttons (i + gear).
    private let trailingActionsWidth: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                locationRow
                monthRow
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

    private var locationRow: some View {
        // Top-align so Map stays with the top of the Location pill when the name wraps to two lines
        // (center would float Map mid-pill). Equal-width pills + always-show “Map” unchanged.
        HStack(alignment: .top, spacing: 12) {
            locationControl
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingActionsSlot {
                if let place, let url = PlaceMaps.appleMapsURL(for: place) {
                    mapButton(place: place, url: url)
                }
            }
        }
    }

    private var monthRow: some View {
        HStack(alignment: .center, spacing: 12) {
            monthControl
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingActionsSlot {
                HStack(spacing: 0) {
                    if place != nil {
                        infoButton
                    }
                    settingsButton
                }
            }
        }
    }

    /// Fixed-width trailing column shared by both rows (Map on Location; i/gear on Month).
    /// ZStack + clear base so an empty Location trailing slot still reserves width (EmptyView would not).
    private func trailingActionsSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .trailing) {
            Color.clear
            content()
        }
        .frame(width: trailingActionsWidth, height: 44, alignment: .trailing)
    }

    private var locationControl: some View {
        // Menu alone sizes to label ideal width; chrome fills the row so both pills match.
        valueMenuChrome(
            text: selectedLocationDisplayName,
            accessibilityLabel: "Location",
            accessibilityHint: "Choose an imported place, merge lists, manage saved imports, or add a location via eBird API or barchart"
        ) {
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
        }
    }

    private var monthControl: some View {
        valueMenuChrome(
            text: model.selectedMonthName,
            accessibilityLabel: "Month",
            accessibilityHint: "Imported lists use this month’s eBird frequencies"
        ) {
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
        }
    }

    /// Value pill fills offered width; invisible Menu overlay supplies the picker (avoids Menu content-sizing the chrome).
    private func valueMenuChrome<MenuContent: View>(
        text: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        valueLabel(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                Menu(content: menuContent) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(text)
                .accessibilityHint(accessibilityHint)
            }
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
            // Explicit HStack (not Label): Label can collapse to icon-only in a tight trailing slot.
            HStack(spacing: 4) {
                Image(systemName: "map")
                Text("Map")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            // Fill the fixed trailing slot so Map cannot widen past i+gear’s reserved width.
            .frame(maxWidth: .infinity, minHeight: 44)
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
