import SwiftUI

struct BirdDetailView: View {
    @EnvironmentObject private var model: GuideModel
    var species: Species
    var place: ResolvedPlace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Likelihood.label(for: species, frequency: model.frequency(for: species, in: place)).uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(species.origin == "introduced" ? GuideColor.rust : GuideColor.green)
                Text(species.commonName)
                    .font(.system(size: 34, weight: .regular, design: .serif))
                Text(species.scientificName)
                    .font(.title3.italic())
                    .foregroundStyle(GuideColor.muted)
                if let frequency = model.frequency(for: species, in: place) {
                    Text("\(model.selectedMonthName) checklist rate \(frequencyPercent(frequency)) (mean of eBird week columns)")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.green)
                }
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

                sectionLabel("Time of day")
                Text(ActiveTime.detailCaption(for: species))
                    .fixedSize(horizontal: false, vertical: true)

                sectionLabel(species.dimorphic ? "Male and female" : "Sexes")
                Text(species.sexes)
                    .fixedSize(horizontal: false, vertical: true)

                if species.dimorphic {
                    sectionLabel("Photos")
                    Text("Male and female are shown separately when openly licensed photographs are available.")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 14) {
                    ForEach(displayPhotos) { photo in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(photoDisplayTitle(photo))
                                .font(.caption.weight(.semibold))
                                .tracking(1.1)
                                .foregroundStyle(GuideColor.green)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                            ZoomablePhoto(path: photo.src, alt: photo.alt, label: photoDisplayTitle(photo))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(photoDisplayTitle(photo))
                                    .font(.system(.title3, design: .serif))
                                Text("Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view.")
                                    .font(.caption)
                                    .foregroundStyle(GuideColor.muted)
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

                if species.dimorphic && !hasMaleAndFemalePhotos {
                    Text("An openly licensed male or female photograph is still missing for this species. The app shows what is available and does not invent a second image.")
                        .font(.footnote)
                        .foregroundStyle(GuideColor.rust)
                }

                Text("Notes follow \(place.isOutside ? place.coverage.label : place.displayName). Habitat lines are a typical place to look, not a guarantee for a given day. Likelihood and time-of-day labels are estimates.")
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
            return StratumInfo(id: id, label: "Ground", hint: "On the ground, a lawn, mud, or the water")
        case "low":
            return StratumInfo(id: id, label: "Low", hint: "Shrubs, low branches, and the understory")
        case "mid":
            return StratumInfo(id: id, label: "Mid", hint: "The middle of the forest, or a small tree")
        case "canopy":
            return StratumInfo(id: id, label: "Canopy", hint: "Crowns of tall trees")
        case "sky":
            return StratumInfo(id: id, label: "Sky", hint: "Overhead — flying, soaring, or hawking in open air")
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

    private var displayPhotos: [Photo] {
        let order = ["male": 0, "female": 1, "either": 2, "unsexed": 3, "illustration": 4]
        let sorted = species.photos.sorted {
            (order[$0.role] ?? 9, $0.label) < (order[$1.role] ?? 9, $1.label)
        }
        if species.dimorphic {
            return sorted
        }
        // Monomorphic: one photo is enough.
        return Array(sorted.prefix(1))
    }

    private var hasMaleAndFemalePhotos: Bool {
        let roles = Set(displayPhotos.map(\.role))
        return roles.contains("male") && roles.contains("female")
    }

    private func photoDisplayTitle(_ photo: Photo) -> String {
        switch photo.role {
        case "male": return "Male"
        case "female": return "Female"
        case "either": return "Sexes look alike"
        case "unsexed": return "Sex not labeled"
        case "illustration": return "Historical illustration"
        default: return photo.label
        }
    }

    private func frequencyPercent(_ value: Double) -> String {
        if value <= 0 { return "0%" }
        if value < 0.01 { return "<1%" }
        return "\(Int((value * 100).rounded()))%"
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
