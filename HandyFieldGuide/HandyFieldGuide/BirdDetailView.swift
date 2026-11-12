import SwiftUI

struct BirdDetailView: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var species: Species
    var place: ResolvedPlace

    @State private var attributionPhoto: Photo?
    @State private var choosePhotoRequest: ChooseSpeciesPhotoRequest?

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
                dimorphismBadge
                if !species.alsoCalled.isEmpty {
                    Text("Also called \(species.alsoCalled.joined(separator: ", "))")
                        .foregroundStyle(GuideColor.muted)
                }
                if !species.alsoScientific.isEmpty {
                    Text("Also listed as \(species.alsoScientific.joined(separator: ", "))")
                        .foregroundStyle(GuideColor.muted)
                }

                let habitatText = place.habitat(for: species)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stratumNote = species.stratumNote
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let knownStrata = species.strata.compactMap { stratum($0) }
                if !habitatText.isEmpty || !knownStrata.isEmpty || !stratumNote.isEmpty {
                    // One section for microhabitat notes and habitat-zone (stratum) labels.
                    sectionLabel("Where you find it")
                    if !habitatText.isEmpty {
                        Text(habitatText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !knownStrata.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(knownStrata, id: \.id) { info in
                                HStack(spacing: 10) {
                                    StratumIcon(id: info.id, size: 44)
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
                    if !stratumNote.isEmpty {
                        Text(stratumNote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if ActiveTime.hasKnownTimes(for: species) {
                    sectionLabel("Time of day")
                    Text(ActiveTime.detailCaption(for: species))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !displayPhotos.isEmpty || canOfferFindPhoto {
                    sectionLabel("Photos")
                }

                photoGallery

                if displayPhotos.isEmpty, canOfferFindPhoto {
                    Button {
                        choosePhotoRequest = makeChooseRequest(role: defaultFindRole, currentFileTitle: "")
                    } label: {
                        Text("Find a photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideChipStyle(selected: false))
                    .accessibilityHint("Searches Wikimedia Commons for an open-licence photo")
                }

                if species.dimorphic && !hasMaleAndFemalePhotos {
                    Text("An openly licensed male or female photograph is still missing for this species. The app shows what is available and does not invent a second image.")
                        .font(.footnote)
                        .foregroundStyle(GuideColor.rust)
                    if canOfferFindPhoto {
                        ForEach(missingDimorphicRoles, id: \.self) { role in
                            Button {
                                choosePhotoRequest = makeChooseRequest(role: role, currentFileTitle: "")
                            } label: {
                                Text(role == "male" ? "Find male photo" : "Find female photo")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(GuideChipStyle(selected: false))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: detailMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .guideBackground()
        .navigationTitle(species.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $attributionPhoto) { photo in
            PhotoAttributionSheet(photo: photo)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $choosePhotoRequest) { request in
            ChooseSpeciesPhotoSheet(request: request)
                .environmentObject(model)
        }
    }

    /// On iPad, keep readable line length without stretching body copy edge-to-edge.
    private var detailMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 900 : 720
    }

    /// Side-by-side male/female photos when the detail column is wide enough.
    private var usesSideBySidePhotos: Bool {
        horizontalSizeClass == .regular && displayPhotos.count >= 2
    }

    @ViewBuilder
    private var photoGallery: some View {
        if usesSideBySidePhotos {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                spacing: 14
            ) {
                ForEach(displayPhotos) { photo in
                    photoCard(photo)
                }
            }
        } else {
            VStack(spacing: 14) {
                ForEach(displayPhotos) { photo in
                    photoCard(photo)
                }
            }
        }
    }

    private func photoCard(_ photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if showsPhotoRoleLabel(photo) {
                    Text(photoDisplayTitle(photo))
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(GuideColor.green)
                }
                Spacer(minLength: 0)
                photoAttrBadge(for: photo)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            ZoomablePhoto(
                path: photo.src,
                alt: photo.alt,
                label: photoAccessibilityLabel(photo),
                cacheRevision: model.photoCache.revision,
                onChooseDifferentPhoto: canOfferFindPhoto ? {
                    choosePhotoRequest = makeChooseRequest(role: photo.role, currentFileTitle: photo.file)
                } : nil
            )

            VStack(alignment: .leading, spacing: 8) {
                if showsPhotoRoleLabel(photo) {
                    Text(photoDisplayTitle(photo))
                        .font(.system(.title3, design: .serif))
                }
                Text("Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view.")
                    .font(.caption)
                    .foregroundStyle(GuideColor.muted)
                if canOfferFindPhoto {
                    Button {
                        choosePhotoRequest = makeChooseRequest(role: photo.role, currentFileTitle: photo.file)
                    } label: {
                        Text(choosePhotoButtonTitle(for: photo.role))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GuideColor.rust)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches Wikimedia Commons for another open-licence photo")
                }
            }
            .padding(10)
        }
        .background(GuideColor.card)
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(GuideColor.line, lineWidth: 1)
        }
    }

    private var canOfferFindPhoto: Bool {
        // Slash / provisional taxa are not single species accounts.
        !species.tags.contains("flagged-taxon")
    }

    private var defaultFindRole: String {
        species.dimorphic ? "male" : "either"
    }

    private var missingDimorphicRoles: [String] {
        guard species.dimorphic else { return [] }
        let have = Set(displayPhotos.map(\.role))
        var missing: [String] = []
        if !have.contains("male") { missing.append("male") }
        if !have.contains("female") { missing.append("female") }
        return missing
    }

    private func choosePhotoButtonTitle(for role: String) -> String {
        switch role {
        case "male": return "Find another male photo"
        case "female": return "Find another female photo"
        default: return "Find another photo"
        }
    }

    private func makeChooseRequest(role: String, currentFileTitle: String) -> ChooseSpeciesPhotoRequest {
        ChooseSpeciesPhotoRequest(
            speciesId: species.id,
            commonName: species.commonName,
            scientificName: species.scientificName,
            alsoCalled: species.alsoCalled,
            alsoScientific: species.alsoScientific,
            aliases: species.aliases,
            dimorphic: species.dimorphic,
            role: role,
            currentFileTitle: currentFileTitle
        )
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

    private var dimorphismBadge: some View {
        let title = species.dimorphic ? "Sexually dimorphic" : "Not sexually dimorphic"
        let subtitle = species.dimorphic ? "Sexes do not look alike" : "Sexes look alike"
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(0.6)
            Text(subtitle)
                .font(.caption2)
        }
        .foregroundStyle(GuideColor.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(GuideColor.green.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private func photoAttrBadge(for photo: Photo) -> some View {
        Button {
            attributionPhoto = photo
        } label: {
            Text("Photo Attr")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(GuideColor.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(GuideColor.green.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo attribution")
        .accessibilityHint("Shows photographer, licence, and source")
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

    /// Male/female role labels stay for dimorphic species. Other roles do not
    /// repeat “sexes look alike” — the dimorphism badge already covers that.
    private func showsPhotoRoleLabel(_ photo: Photo) -> Bool {
        photo.role == "male" || photo.role == "female" || photo.role == "illustration"
    }

    private func photoDisplayTitle(_ photo: Photo) -> String {
        switch photo.role {
        case "male": return "Male"
        case "female": return "Female"
        case "illustration": return "Historical illustration"
        default: return photo.label.isEmpty ? "Photo" : photo.label
        }
    }

    private func photoAccessibilityLabel(_ photo: Photo) -> String {
        if showsPhotoRoleLabel(photo) {
            return photoDisplayTitle(photo)
        }
        return photo.alt.isEmpty ? species.commonName : photo.alt
    }
}

private struct PhotoAttributionSheet: View {
    var photo: Photo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Photographer") {
                    if let source = URL(string: photo.sourceUrl), !photo.author.isEmpty {
                        Link(photo.author, destination: source)
                    } else if !photo.author.isEmpty {
                        Text(photo.author)
                    } else {
                        Text("Photographer not listed")
                            .foregroundStyle(GuideColor.muted)
                    }
                }
                Section("Licence") {
                    if let license = URL(string: photo.licenseUrl), !photo.license.isEmpty {
                        Link(photo.license, destination: license)
                    } else if !photo.license.isEmpty {
                        Text(photo.license)
                    } else {
                        Text("Licence not listed")
                            .foregroundStyle(GuideColor.muted)
                    }
                }
                if let source = URL(string: photo.sourceUrl) {
                    Section("Source") {
                        Link(source.absoluteString, destination: source)
                    }
                }
            }
            .guideBackground()
            .navigationTitle("Photo attribution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(GuideColor.rust)
    }
}
