import PhotosUI
import SwiftUI
import UIKit

struct BirdDetailView: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var species: Species
    var place: ResolvedPlace

    @State private var attributionPhoto: Photo?
    @State private var choosePhotoRequest: ChooseSpeciesPhotoRequest?
    /// Collapsed by default so photos stay near the top on a phone; length / zone peek under the header.
    @State private var sizeExpanded = false
    @State private var whereExpanded = false
    /// PhotosPicker selection for attaching a user photo to a specific role (or the default empty slot).
    @State private var libraryPickerRole: String?
    @State private var libraryPickerItems: [PhotosPickerItem] = []
    @State private var photoError: String?
    @State private var isGalleryDropTargeted = false
    @State private var dropTargetedRole: String?
    /// Presented when the user chooses among multiple own photos to remove.
    @State private var removeLibraryRequest: RemoveLibraryPhotoRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Likelihood.label(for: species, frequency: model.frequency(for: species, in: place)).uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(species.origin == "introduced" ? GuideColor.rust : GuideColor.green)
                Text(species.commonName)
                    .font(.system(size: 34, weight: .regular, design: .serif))
                if SpeciesDescription.hasText(for: species) {
                    Text(SpeciesDescription.text(for: species))
                        .font(.body)
                        .foregroundStyle(GuideColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

                if BirdSize.hasLength(species) {
                    CollapsibleDetailSection(
                        title: "Size",
                        collapsedSummary: BirdSize.line(for: species),
                        isExpanded: $sizeExpanded
                    ) {
                        Text(BirdSize.line(for: species))
                            .fixedSize(horizontal: false, vertical: true)
                        BirdSizeScale(lengthCm: species.lengthCm)
                    }
                }

                let habitatText = place.habitat(for: species)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stratumNote = species.stratumNote
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let knownStrata = species.strata.compactMap { stratum($0) }
                if !habitatText.isEmpty || !knownStrata.isEmpty || !stratumNote.isEmpty {
                    // One section for microhabitat notes and habitat-zone (stratum) labels.
                    CollapsibleDetailSection(
                        title: "Where you find it",
                        collapsedSummary: whereCollapsedSummary(
                            habitatText: habitatText,
                            knownStrata: knownStrata
                        ),
                        isExpanded: $whereExpanded
                    ) {
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
                }

                if ActiveTime.hasKnownTimes(for: species) {
                    sectionLabel("Time of day")
                    Text(ActiveTime.detailCaption(for: species))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !displayPhotos.isEmpty || canOfferOwnPhoto || canOfferFindPhoto {
                    sectionLabel("Photos")
                }

                photoGallery

                if displayPhotos.isEmpty, !species.dimorphic {
                    emptyPhotoActions
                }

                if let photoError {
                    Text(photoError)
                        .font(.footnote)
                        .foregroundStyle(GuideColor.rust)
                }

                if species.dimorphic && !hasMaleAndFemalePhotos {
                    Text("An openly licensed male or female photograph is still missing for this species. The app shows what is available and does not invent a second image. You can still add your own photo.")
                        .font(.footnote)
                        .foregroundStyle(GuideColor.rust)
                    if canOfferFindPhoto || canOfferOwnPhoto {
                        ForEach(missingDimorphicRoles, id: \.self) { role in
                            ownAndFindPhotoButtons(role: role, currentFileTitle: "")
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
        .sheet(item: $removeLibraryRequest) { request in
            RemoveLibraryPhotoSheet(
                photos: request.photos,
                initiallySelectedID: request.initiallySelectedID
            ) { selectedID in
                clearLibraryPhoto(role: selectedID)
                removeLibraryRequest = nil
            } onCancel: {
                removeLibraryRequest = nil
            }
        }
        .onChange(of: libraryPickerItems) { _, newItems in
            guard !newItems.isEmpty, let role = libraryPickerRole else { return }
            Task { await importLibraryPhotos(from: newItems, role: role) }
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
        Group {
            if usesSideBySidePhotos {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(displayPhotos) { photo in
                        photoCard(photo)
                    }
                }
            } else if !displayPhotos.isEmpty {
                VStack(spacing: 14) {
                    ForEach(displayPhotos) { photo in
                        photoCard(photo)
                    }
                }
            } else {
                emptyPhotoDropZone
            }
        }
        .userPhotoDrop(
            isTargeted: $isGalleryDropTargeted,
            enabled: canOfferOwnPhoto && displayPhotos.isEmpty
        ) { jpegs in
            applyDroppedJPEGs(jpegs, role: defaultFindRole)
        }
    }

    private var emptyPhotoDropZone: some View {
        GuideColor.green.opacity(isGalleryDropTargeted ? 0.18 : 0.10)
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .overlay {
                VStack(spacing: 8) {
                    Text(isGalleryDropTargeted ? "Drop to add your photo" : "No photo yet")
                        .font(.system(.title3, design: .serif))
                    Text(emptyPhotoHint)
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(
                        isGalleryDropTargeted ? GuideColor.green : GuideColor.line,
                        lineWidth: isGalleryDropTargeted ? 3 : 1
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(emptyPhotoAccessibilityHint)
    }

    private var emptyPhotoHint: String {
        if UserPhotoImport.supportsPaste {
            return "Add from your library, paste a photo copied from Photos, or search Wikimedia Commons. Pasted images are resized before saving."
        }
        return "Add from your library, drag and drop a photo here, or search Wikimedia Commons."
    }

    private var emptyPhotoAccessibilityHint: String {
        if UserPhotoImport.supportsPaste {
            return "Paste a photo copied from Photos, or add one from your library"
        }
        return "Drop a photo here to attach your own image"
    }

    @ViewBuilder
    private var emptyPhotoActions: some View {
        ownAndFindPhotoButtons(role: defaultFindRole, currentFileTitle: "")
    }

    @ViewBuilder
    private func ownAndFindPhotoButtons(role: String, currentFileTitle: String) -> some View {
        VStack(spacing: 8) {
            if canOfferOwnPhoto {
                PhotosPicker(
                    selection: Binding(
                        get: { libraryPickerRole == role ? libraryPickerItems : [] },
                        set: { newValue in
                            libraryPickerRole = role
                            libraryPickerItems = newValue
                        }
                    ),
                    maxSelectionCount: 1,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Text(ownPhotoButtonTitle(for: role, replacing: false))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GuideChipStyle(selected: true))
                .accessibilityHint(ownPhotoAccessibilityHint(replacing: false))

                if UserPhotoImport.supportsPaste {
                    UserPhotoPasteChip(title: pastePhotoButtonTitle(for: role, replacing: false)) { jpegs in
                        applyPastedJPEGs(jpegs, role: role)
                    } onEmpty: {
                        photoError = "Copy a photo in Photos first, then paste it here."
                    }
                }
            }
            if canOfferFindPhoto {
                Button {
                    choosePhotoRequest = makeChooseRequest(role: role, currentFileTitle: currentFileTitle)
                } label: {
                    Text(role == "male" ? "Find male photo" : role == "female" ? "Find female photo" : "Find a photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GuideChipStyle(selected: false))
                .accessibilityHint("Searches Wikimedia Commons for an open-licence photo")
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
                if photo.isLibraryPhoto {
                    PhotoSourceBadge(source: .library)
                } else {
                    photoAttrBadge(for: photo)
                }
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
            .userPhotoDrop(
                isTargeted: Binding(
                    get: { dropTargetedRole == photo.role },
                    set: { dropTargetedRole = $0 ? photo.role : nil }
                ),
                enabled: canOfferOwnPhoto
            ) { jpegs in
                applyDroppedJPEGs(jpegs, role: photo.role)
            }

            VStack(alignment: .leading, spacing: 8) {
                if showsPhotoRoleLabel(photo) {
                    Text(photoDisplayTitle(photo))
                        .font(.system(.title3, design: .serif))
                }
                Text(photoHelpCaption(isLibrary: photo.isLibraryPhoto))
                .font(.caption)
                .foregroundStyle(GuideColor.muted)

                if canOfferOwnPhoto {
                    PhotosPicker(
                        selection: Binding(
                            get: { libraryPickerRole == photo.role ? libraryPickerItems : [] },
                            set: { newValue in
                                libraryPickerRole = photo.role
                                libraryPickerItems = newValue
                            }
                        ),
                        maxSelectionCount: 1,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Text(ownPhotoButtonTitle(for: photo.role, replacing: true))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideChipStyle(selected: true))
                    .accessibilityHint(ownPhotoAccessibilityHint(replacing: true))

                    if UserPhotoImport.supportsPaste {
                        UserPhotoPasteChip(title: pastePhotoButtonTitle(for: photo.role, replacing: true)) { jpegs in
                            applyPastedJPEGs(jpegs, role: photo.role)
                        } onEmpty: {
                            photoError = "Copy a photo in Photos first, then paste it here."
                        }
                    }
                }

                if photo.isLibraryPhoto {
                    Button {
                        presentRemoveLibraryPhoto(preferringRole: photo.role)
                    } label: {
                        Text(libraryPhotosForRemoval.count > 1 ? "Remove a photo…" : "Remove my photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideChipStyle(selected: false))
                    .accessibilityHint(
                        libraryPhotosForRemoval.count > 1
                            ? "Choose which of your photos to remove so a Field Guide stock image can show again when available"
                            : "Removes your photo so a Field Guide stock image can show again when available"
                    )
                }

                if canOfferFindPhoto {
                    // Chip matches empty-state “Find a photo” so the replace action is obvious on detail.
                    Button {
                        choosePhotoRequest = makeChooseRequest(role: photo.role, currentFileTitle: photo.file)
                    } label: {
                        Text(choosePhotoButtonTitle(for: photo.role))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideChipStyle(selected: false))
                    .accessibilityHint("Searches Wikimedia Commons for another open-licence photo")
                }
            }
            .padding(10)
        }
        .background(GuideColor.card)
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(
                    dropTargetedRole == photo.role ? GuideColor.green : GuideColor.line,
                    lineWidth: dropTargetedRole == photo.role ? 3 : 1
                )
        }
    }

    /// Own photos are allowed for any real species account (not slash / provisional taxa).
    private var canOfferOwnPhoto: Bool {
        !species.tags.contains("flagged-taxon")
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

    private func ownPhotoButtonTitle(for role: String, replacing: Bool) -> String {
        let verb = replacing ? "Replace with my" : "Add my"
        switch role {
        case "male": return "\(verb) male photo"
        case "female": return "\(verb) female photo"
        default: return "\(verb) photo"
        }
    }

    private func pastePhotoButtonTitle(for role: String, replacing: Bool) -> String {
        let verb = replacing ? "Paste to replace" : "Paste"
        switch role {
        case "male": return "\(verb) male photo"
        case "female": return "\(verb) female photo"
        default: return "\(verb) photo"
        }
    }

    private func ownPhotoAccessibilityHint(replacing: Bool) -> String {
        if UserPhotoImport.supportsPaste {
            return replacing
                ? "Replaces this photo with one from your library, or paste a photo copied from Photos"
                : "Adds your photo from the library, or paste a photo copied from Photos"
        }
        return replacing
            ? "Replaces this photo with one from your library, or drop an image onto the photo"
            : "Adds your photo from the library, or drop a photo onto the photo area"
    }

    private func photoHelpCaption(isLibrary: Bool) -> String {
        if UserPhotoImport.supportsPaste {
            return isLibrary
                ? "Your photo. Pinch or double-tap to zoom; drag to pan. Long-press for full screen. Paste another photo from Photos to replace it — images are resized before saving."
                : "Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view. Paste your own photo from Photos, or use the buttons below."
        }
        return isLibrary
            ? "Your photo. Pinch or double-tap to zoom; drag to pan. Long-press for full screen. Drop another photo here to replace it."
            : "Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view. Drop your own photo here, or use the buttons below."
    }

    @MainActor
    private func importLibraryPhotos(from items: [PhotosPickerItem], role: String) async {
        photoError = nil
        var failures = 0
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let jpeg = UserPhotoImport.jpeg(from: data) else {
                    failures += 1
                    continue
                }
                try saveLibraryJPEG(jpeg.data, width: jpeg.width, height: jpeg.height, role: role)
            } catch {
                failures += 1
                photoError = error.localizedDescription
            }
        }
        if failures > 0 && photoError == nil {
            photoError = "That photo could not be read. Try another image from your library."
        }
        libraryPickerItems = []
        libraryPickerRole = nil
    }

    @MainActor
    private func applyDroppedJPEGs(_ jpegs: [Data], role: String) {
        applyEncodedJPEGs(
            jpegs,
            role: role,
            emptyMessage: "That drop could not be read. Try a JPEG or PNG, or use Add my photo."
        )
    }

    @MainActor
    private func applyPastedJPEGs(_ jpegs: [Data], role: String) {
        applyEncodedJPEGs(
            jpegs,
            role: role,
            emptyMessage: "Copy a photo in Photos first, then paste it here."
        )
    }

    /// Drop / paste pipelines already downscale and encode JPEG; read pixel size without re-compressing.
    @MainActor
    private func applyEncodedJPEGs(_ jpegs: [Data], role: String, emptyMessage: String) {
        photoError = nil
        guard let first = jpegs.first else {
            photoError = emptyMessage
            return
        }
        guard let image = UIImage(data: first) else {
            photoError = emptyMessage
            return
        }
        let width = max(1, Int((image.size.width * image.scale).rounded()))
        let height = max(1, Int((image.size.height * image.scale).rounded()))
        do {
            try saveLibraryJPEG(first, width: width, height: height, role: role)
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func saveLibraryJPEG(_ data: Data, width: Int, height: Int, role: String) throws {
        try model.photoCache.saveLibraryPhoto(
            jpegData: data,
            width: width,
            height: height,
            speciesId: species.id,
            commonName: species.commonName,
            scientificName: species.scientificName == "—" ? nil : species.scientificName,
            dimorphic: species.dimorphic,
            role: role
        )
    }

    private func clearLibraryPhoto(role: String) {
        model.photoCache.clearCachedPhoto(speciesId: species.id, role: role)
        photoError = nil
    }

    /// Library attaches currently shown (one per role when present on disk).
    private var libraryPhotosForRemoval: [RemovableLibraryPhoto] {
        displayPhotos.compactMap { photo in
            guard photo.isLibraryPhoto, BundleImages.url(for: photo.src) != nil else { return nil }
            return RemovableLibraryPhoto(
                id: photo.role,
                path: photo.src,
                title: removalTitle(for: photo)
            )
        }
    }

    private func removalTitle(for photo: Photo) -> String {
        switch photo.role {
        case "male": return "Male — my photo"
        case "female": return "Female — my photo"
        default: return "My photo"
        }
    }

    /// One library attach: remove it. Several (e.g. male + female): open the chooser.
    private func presentRemoveLibraryPhoto(preferringRole role: String) {
        let candidates = libraryPhotosForRemoval
        guard !candidates.isEmpty else { return }
        if candidates.count == 1, let only = candidates.first {
            clearLibraryPhoto(role: only.id)
            return
        }
        let initial = candidates.contains(where: { $0.id == role }) ? role : candidates.first?.id
        removeLibraryRequest = RemoveLibraryPhotoRequest(
            photos: candidates,
            initiallySelectedID: initial
        )
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

    /// When collapsed: habitat zones if known, otherwise a short habitat lead.
    private func whereCollapsedSummary(habitatText: String, knownStrata: [StratumInfo]) -> String {
        if !knownStrata.isEmpty {
            let zones = knownStrata.map(\.label).joined(separator: " · ")
            return "Habitat zones: \(zones)"
        }
        guard !habitatText.isEmpty else { return "" }
        if let end = habitatText.firstIndex(where: { ".!?".contains($0) }) {
            let sentence = String(habitatText[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count <= 90 { return sentence }
        }
        if habitatText.count <= 90 { return habitatText }
        let idx = habitatText.index(habitatText.startIndex, offsetBy: 87)
        return String(habitatText[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
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

/// Tappable section header with chevron; collapsed state keeps a one-line summary readable.
private struct CollapsibleDetailSection<Content: View>: View {
    var title: String
    var collapsedSummary: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(GuideColor.muted)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GuideColor.muted)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")

            if isExpanded {
                content()
            } else if !collapsedSummary.isEmpty {
                Text(collapsedSummary)
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(false)
            }
        }
        .padding(.top, 8)
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
