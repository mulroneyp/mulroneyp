import SwiftUI

struct BirdDetailView: View {
    var species: Species
    var place: ResolvedPlace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(species.status.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(species.origin == "introduced" ? GuideColor.rust : GuideColor.green)
                Text(species.commonName)
                    .font(.system(size: 34, weight: .regular, design: .serif))
                Text(species.scientificName)
                    .font(.title3.italic())
                    .foregroundStyle(GuideColor.muted)
                if !species.alsoCalled.isEmpty {
                    Text("Also called \(species.alsoCalled.joined(separator: ", "))")
                        .foregroundStyle(GuideColor.muted)
                }
                if !species.alsoScientific.isEmpty {
                    Text("Also listed as \(species.alsoScientific.joined(separator: ", "))")
                        .foregroundStyle(GuideColor.muted)
                }

                sectionLabel("Where you find it")
                Text(place.habitat(for: species))
                    .fixedSize(horizontal: false, vertical: true)

                sectionLabel("Height")
                VStack(spacing: 8) {
                    ForEach(species.strata, id: \.self) { id in
                        if let info = stratum(id) {
                            HStack(spacing: 10) {
                                StratumIcon(id: id, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.label).font(.headline)
                                    Text(info.hint)
                                        .font(.subheadline)
                                        .foregroundStyle(GuideColor.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(GuideColor.card)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(GuideColor.line, lineWidth: 1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Text(species.stratumNote)
                    .fixedSize(horizontal: false, vertical: true)

                sectionLabel(species.dimorphic ? "Male and female" : "Sexes")
                Text(species.sexes)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 14) {
                    ForEach(species.photos) { photo in
                        VStack(alignment: .leading, spacing: 0) {
                            BundlePhoto(path: photo.src, alt: photo.alt)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(photo.label)
                                    .font(.system(.title3, design: .serif))
                                credit(photo)
                            }
                            .padding(10)
                        }
                        .background(GuideColor.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(GuideColor.line, lineWidth: 1)
                        }
                    }
                }

                Text("Notes follow \(place.isOutside ? place.coverage.label : place.displayName). A named park is a typical public place, not a guarantee for a given day.")
                    .font(.footnote)
                    .foregroundStyle(GuideColor.muted)
                    .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .guideBackground()
        .navigationTitle(species.commonName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stratum(_ id: String) -> StratumInfo? {
        // Stratum copy is the same for every coverage and lives on the guide file.
        // The detail view receives only the species and place, so the labels are local.
        switch id {
        case "ground":
            return StratumInfo(id: id, label: "Ground", hint: "Lawns, mud, shore, and the water surface")
        case "low":
            return StratumInfo(id: id, label: "Low", hint: "Shrubs, reeds, fences, and low branches")
        case "mid":
            return StratumInfo(id: id, label: "Mid", hint: "Small trees and the open mid-storey")
        case "canopy":
            return StratumInfo(id: id, label: "Canopy", hint: "Crowns of tall trees")
        default:
            return nil
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(GuideColor.muted)
            .padding(.top, 8)
    }

    @ViewBuilder
    private func credit(_ photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let source = URL(string: photo.sourceUrl) {
                HStack(spacing: 0) {
                    Text("Photo: ")
                    Link(photo.author, destination: source)
                }
            } else {
                Text("Photo: \(photo.author)")
            }
            if let license = URL(string: photo.licenseUrl) {
                Link(photo.license, destination: license)
            } else if !photo.license.isEmpty {
                Text(photo.license)
            }
        }
        .font(.caption)
        .foregroundStyle(GuideColor.muted)
        .tint(GuideColor.rust)
    }
}
