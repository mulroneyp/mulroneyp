import SwiftUI

/// Top Life List controls under the nav title — same overall chrome as
/// `HomeFiltersView`, with Country + Map on the first row and Bird Count Total
/// (display only) + Field Guide on the second.
struct LifeListFiltersView: View {
    /// Empty string means Global; otherwise an ISO country code.
    @Binding var selectedCountryCode: String
    var availableCountryCodes: [String]
    var birdCountTotal: Int
    var lifeListTotal: Int
    /// Active Field Guide place, when one is open — used for Map when Global.
    var place: ResolvedPlace?
    var onFieldGuide: () -> Void

    @Environment(\.openURL) private var openURL

    /// Slightly wider than home’s Map / Life List column so “Field Guide” fits.
    private let trailingActionsWidth: CGFloat = 118

    private var selectedCountryLabel: String {
        if selectedCountryCode.isEmpty { return "Global" }
        return LifeListEntry.countryDisplayName(code: selectedCountryCode)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                countryRow
                birdCountRow
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

    private var countryRow: some View {
        HStack(alignment: .top, spacing: 12) {
            countryControl
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingActionsSlot {
                mapButton
            }
        }
    }

    private var birdCountRow: some View {
        HStack(alignment: .center, spacing: 12) {
            birdCountTotalLabel
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingActionsSlot {
                fieldGuideButton
            }
        }
    }

    private func trailingActionsSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .trailing) {
            Color.clear
            content()
        }
        .frame(width: trailingActionsWidth, height: 44, alignment: .trailing)
    }

    private var countryControl: some View {
        valueLabel(selectedCountryLabel, showsChevron: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                Menu {
                    Picker("Country", selection: $selectedCountryCode) {
                        Text("Global").tag("")
                        ForEach(availableCountryCodes, id: \.self) { code in
                            Text(LifeListEntry.countryDisplayName(code: code)).tag(code)
                        }
                    }
                } label: {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Country")
                .accessibilityValue(selectedCountryLabel)
                .accessibilityHint("Filter the life list by country, or show Global")
            }
    }

    /// Display-only count pill — same chrome as Month, without a menu or chevron.
    private var birdCountTotalLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BIRD COUNT TOTAL")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GuideColor.green)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(birdCountTotal)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(GuideColor.green)
                if birdCountTotal != lifeListTotal {
                    Text("of \(lifeListTotal)")
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(GuideColor.green.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bird count total \(birdCountTotal)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func valueLabel(_ text: String, showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
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

    @ViewBuilder
    private var mapButton: some View {
        if let url = mapURL {
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
            .accessibilityLabel(mapAccessibilityLabel)
            .accessibilityHint(mapAccessibilityHint)
        }
    }

    private var fieldGuideButton: some View {
        Button(action: onFieldGuide) {
            HStack(spacing: 4) {
                Image(systemName: "bird")
                Text("Field Guide")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
        .accessibilityLabel("Field Guide")
        .accessibilityHint("Returns to the Field Guide home")
    }

    private var mapURL: URL? {
        if !selectedCountryCode.isEmpty {
            return appleMapsSearchURL(query: LifeListEntry.countryDisplayName(code: selectedCountryCode))
        }
        if let place {
            return PlaceMaps.appleMapsURL(for: place)
        }
        return nil
    }

    private var mapAccessibilityLabel: String {
        if !selectedCountryCode.isEmpty {
            return "Open \(selectedCountryLabel) in Maps"
        }
        if let place {
            return "Open \(place.displayName) in Maps"
        }
        return "Map"
    }

    private var mapAccessibilityHint: String {
        if !selectedCountryCode.isEmpty {
            return "Searches Maps for \(selectedCountryLabel)"
        }
        if let place, let query = PlaceMaps.searchQuery(for: place) {
            return "Searches Maps for \(query)"
        }
        return ""
    }

    private func appleMapsSearchURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }
}
