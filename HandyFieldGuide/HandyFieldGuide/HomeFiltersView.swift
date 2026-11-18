import SwiftUI

/// Top home controls under the app title: Location and Month value buttons (no Settings gear here).
struct HomeFiltersView: View {
    @EnvironmentObject private var model: GuideModel
    var onAddLocation: () -> Void
    var onManageLocations: () -> Void
    var onMergeLists: () -> Void

    private var importedLocationOptions: [LocationOption] {
        model.imports.locations.map {
            .init(id: $0.id, title: $0.name, query: $0.name)
        }
    }

    /// Place name next to the Location button, or “Choose Location” when none is active.
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
        HStack(alignment: .center, spacing: 12) {
            locationControl
            Text(selectedLocationDisplayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GuideColor.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var monthRow: some View {
        HStack(alignment: .center, spacing: 12) {
            monthControl
            Text(model.selectedMonthName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GuideColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
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
            filterButtonLabel(title: "Location")
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
            filterButtonLabel(title: "Month")
        }
        .accessibilityLabel("Month")
        .accessibilityValue(model.selectedMonthName)
        .accessibilityHint("Imported lists use this month’s eBird frequencies")
    }

    private func filterButtonLabel(title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(GuideColor.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 108, minHeight: 44, alignment: .center)
        .background(GuideColor.green.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
        }
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
