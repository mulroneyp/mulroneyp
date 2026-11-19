import MapKit
import SwiftUI

/// In-app map of life-list sighting pins for the current Country / Global filter.
struct LifeListMapView: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss

    /// Country-filtered entries (all entries when Global).
    var entries: [LifeListEntry]
    /// Empty string = Global.
    var countryCode: String

    @StateObject private var resolver = LifeListMapPinResolver()
    @State private var position: MapCameraPosition = .automatic
    @State private var didFitCamera = false

    private var pins: [LifeListMapPin] {
        LifeListMapPins.pins(from: entries)
    }

    private var titleLabel: String {
        if countryCode.isEmpty { return "Global" }
        return LifeListEntry.countryDisplayName(code: countryCode)
    }

    private var placedPins: [(pin: LifeListMapPin, coordinate: CLLocationCoordinate2D)] {
        pins.compactMap { pin in
            guard let coordinate = resolver.coordinates[pin.id] else { return nil }
            return (pin, coordinate)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                mapContent
                statusBanner
            }
            .guideBackground()
            .navigationTitle("Map · \(titleLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: taskIdentity) {
                didFitCamera = false
                await resolver.resolve(pins: pins, imports: model.imports.locations)
                fitMapIfNeeded(force: true)
            }
            .onChange(of: resolver.resolvedCount) { _, count in
                // Fit once the first pins land; avoid yanking the camera on every geocode.
                if count > 0, !didFitCamera {
                    fitMapIfNeeded(force: true)
                }
            }
        }
    }

    private var taskIdentity: String {
        let pinIDs = pins.map(\.id).joined(separator: ",")
        return "\(countryCode)|\(entries.count)|\(pinIDs)"
    }

    @ViewBuilder
    private var mapContent: some View {
        Map(position: $position) {
            ForEach(placedPins, id: \.pin.id) { item in
                Annotation(item.pin.title, coordinate: item.coordinate, anchor: .bottom) {
                    pinMarker(for: item.pin)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea(edges: .bottom)
    }

    private func pinMarker(for pin: LifeListMapPin) -> some View {
        // Pins only — no title/subtitle callouts on the map (prefs: Map shows pins, no labels).
        Image(systemName: "mappin.circle.fill")
            .font(.title)
            .foregroundStyle(GuideColor.rust)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .accessibilityLabel("\(pin.title), \(pin.subtitle)")
    }

    @ViewBuilder
    private var statusBanner: some View {
        let total = pins.count
        let placed = placedPins.count
        let failed = resolver.failedIDs.count
        if total == 0 {
            banner(text: "No recorded locations on this life list filter yet.")
        } else if resolver.isResolving {
            banner(text: "Placing \(placed) of \(total) sighting locations…")
        } else if placed == 0 {
            banner(text: "Couldn’t place map pins for these locations. Check the place names in your import.")
        } else if placed < total {
            // Shortfall is only real lookup misses (private sites / geocode failures), not a volume cap.
            banner(
                text: "Showing \(placed) of \(total) sighting locations"
                    + (failed > 0
                        ? " · \(failed) could not be placed (unknown or private places)."
                        : ".")
            )
        } else {
            banner(text: "\(placed) sighting location\(placed == 1 ? "" : "s") for \(titleLabel).")
        }
    }

    private func banner(text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(GuideColor.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(GuideColor.paper.opacity(0.94))
            .overlay(alignment: .top) {
                Rectangle().fill(GuideColor.line).frame(height: 1)
            }
    }

    private func fitMapIfNeeded(force: Bool) {
        let coords = placedPins.map(\.coordinate)
        guard !coords.isEmpty else { return }
        guard force || !didFitCamera else { return }
        didFitCamera = true
        if coords.count == 1 {
            position = .region(
                MKCoordinateRegion(
                    center: coords[0],
                    span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.45)
                )
            )
            return
        }
        var minLat = coords[0].latitude
        var maxLat = coords[0].latitude
        var minLng = coords[0].longitude
        var maxLng = coords[0].longitude
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude)
            maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        let latDelta = max((maxLat - minLat) * 1.4, 0.35)
        let lngDelta = max((maxLng - minLng) * 1.4, 0.35)
        position = .region(
            MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
            )
        )
    }
}
