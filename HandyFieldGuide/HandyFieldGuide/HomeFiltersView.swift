import SwiftUI

/// Top home controls under the app title: value labels for Location and Month
/// (tappable pickers), with Map on the Location row and Life List under Map.
/// Info (i) and Settings gear live on the navigation title row (see GuideRootView).
struct HomeFiltersView: View {
    @EnvironmentObject private var model: GuideModel
    /// Active place when a list is open; nil on the empty home state.
    var place: ResolvedPlace?
    var onAddLocation: () -> Void
    var onManageLocations: () -> Void
    var onMergeLists: () -> Void
    var onLifeList: () -> Void

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

    /// Same reserved width on both rows for Map vs Life List so the value pills match.
    /// Wide enough for icon + “Map” / “Life List” labels.
    private let trailingActionsWidth: CGFloat = 108

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
    }

    private var locationRow: some View {
        // Top-align so Map stays with the top of the Location pill when the name wraps.
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
                lifeListButton
            }
        }
    }

    /// Fixed-width trailing column shared by both rows (Map on Location; Life List under Map).
    private func trailingActionsSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .trailing) {
            Color.clear
            content()
        }
        .frame(width: trailingActionsWidth, height: 44, alignment: .trailing)
    }

    private var locationControl: some View {
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
            HStack(spacing: 4) {
                Image(systemName: "map")
                Text("Map")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
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

    private var lifeListButton: some View {
        Button(action: onLifeList) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                Text("Life List")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(GuideColor.green.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
            }
        }
        .foregroundStyle(GuideColor.green)
        .accessibilityLabel("Life List")
        .accessibilityHint("Opens your imported eBird life list")
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
