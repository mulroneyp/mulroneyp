import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Full-screen Life List peer to the Field Guide home: same overall list format,
/// with Country / Map / Bird Count Total / Field Guide in the header chrome.
/// On regular width (iPad / Mac), matches Field Guide’s NavigationSplitView —
/// list on the left, larger photo and info for the selected bird on the right.
struct LifeListView: View {
    /// `nil` = Global (all countries).
    private static let globalCountrySentinel = ""

    @EnvironmentObject private var model: GuideModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Returns to the Field Guide home (peer navigation, not a sheet dismiss).
    var onFieldGuide: () -> Void

    @State private var searchDraft = ""
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var importMessage: String?
    /// iPhone push stack — unchanged compact UX.
    @State private var path = NavigationPath()
    /// iPad / Mac split selection — drives the detail column.
    @State private var selectedEntryID: String?
    /// Empty string means Global; otherwise an ISO country code.
    @State private var selectedCountryCode: String = Self.globalCountrySentinel

    private var usesSplitNavigation: Bool {
        horizontalSizeClass == .regular
    }

    private var contentMaxWidth: CGFloat {
        usesSplitNavigation ? 520 : 720
    }

    private var availableCountryCodes: [String] {
        let codes = Set(model.lifeList.entries.flatMap(\.countryCodes))
        return codes.sorted {
            LifeListEntry.countryDisplayName(code: $0)
                .localizedCaseInsensitiveCompare(LifeListEntry.countryDisplayName(code: $1)) == .orderedAscending
        }
    }

    private var countryFilteredEntries: [LifeListEntry] {
        let entries = model.lifeList.entries
        guard !selectedCountryCode.isEmpty else { return entries }
        return entries.filter { $0.matchesCountryCode(selectedCountryCode) }
    }

    private var filteredEntries: [LifeListEntry] {
        let needle = SpeciesCatalog.normalize(searchDraft)
        let entries = countryFilteredEntries
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            SpeciesCatalog.normalize(entry.commonName).contains(needle)
                || SpeciesCatalog.normalize(entry.scientificName).contains(needle)
                || SpeciesCatalog.normalize(entry.firstRecordedLocation ?? "").contains(needle)
                || SpeciesCatalog.normalize(entry.lastRecordedLocation ?? "").contains(needle)
        }
    }

    var body: some View {
        Group {
            if usesSplitNavigation {
                splitRoot
            } else {
                stackRoot
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onChange(of: availableCountryCodes) { _, codes in
            if !selectedCountryCode.isEmpty, !codes.contains(selectedCountryCode) {
                selectedCountryCode = Self.globalCountrySentinel
            }
        }
        .onChange(of: selectedCountryCode) { _, _ in
            clearStaleSelection()
            path = NavigationPath()
        }
        .onChange(of: searchDraft) { _, _ in
            clearStaleSelection()
        }
        .onChange(of: model.lifeList.entries) { _, _ in
            clearStaleSelection()
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            // Moving between compact/regular (Stage Manager, slide-over) should not leave a stale selection.
            if newValue != .regular {
                selectedEntryID = nil
            } else {
                path = NavigationPath()
            }
        }
    }

    private var stackRoot: some View {
        NavigationStack(path: $path) {
            listColumn
                .navigationDestination(for: String.self) { entryID in
                    if model.lifeList.entry(id: entryID) != nil {
                        LifeListDetailView(entryID: entryID)
                    } else {
                        Text("That bird is not on your life list.")
                            .guideBackground()
                    }
                }
        }
    }

    private var splitRoot: some View {
        NavigationSplitView {
            NavigationStack {
                listColumn
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 520)
        } detail: {
            NavigationStack {
                splitDetail
                    .guideBackground()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var listColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                headerActions

                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(GuideColor.rust)
                }
                if let importMessage {
                    Text(importMessage)
                        .font(.footnote)
                        .foregroundStyle(GuideColor.green)
                }

                if model.lifeList.isEmpty {
                    emptyState
                } else {
                    searchField

                    if filteredEntries.isEmpty {
                        Text(
                            searchDraft.isEmpty
                                ? "No life-list birds match that country."
                                : "No life-list birds match that search."
                        )
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(filteredEntries) { entry in
                            entryRowLink(entry: entry)
                        }
                    }

                        Text(listFooterHelp)
                    .font(.footnote)
                    .foregroundStyle(GuideColor.muted)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            // Match Field Guide: pin the readable column to the leading edge on wide Mac sidebars
            // (default center alignment was centering the Life List).
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .guideBackground()
        .navigationTitle("Life List")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            LifeListFiltersView(
                selectedCountryCode: $selectedCountryCode,
                availableCountryCodes: availableCountryCodes,
                birdCountTotal: countryFilteredEntries.count,
                lifeListTotal: model.lifeList.entries.count,
                filteredEntries: countryFilteredEntries,
                onFieldGuide: onFieldGuide
            )
        }
    }

    @ViewBuilder
    private var splitDetail: some View {
        if let entryID = selectedEntryID,
           model.lifeList.entry(id: entryID) != nil {
            LifeListDetailView(entryID: entryID)
        } else if !model.lifeList.isEmpty {
            ContentUnavailableView {
                Label("Select a bird", systemImage: "bird")
            } description: {
                Text("Choose a species from the life list to see recorded dates, locations, and photos.")
            }
        } else {
            ContentUnavailableView {
                Label("Life List", systemImage: "list.bullet")
            } description: {
                Text("Import an eBird life list CSV, then pick a bird from the list.")
            }
        }
    }

    @ViewBuilder
    private func entryRowLink(entry: LifeListEntry) -> some View {
        let row = LifeListRow(
            entry: entry,
            guideSpecies: model.catalog?.species(forCommonName: entry.commonName),
            photoRevision: model.lifeList.photoRevision,
            isSelected: usesSplitNavigation && selectedEntryID == entry.id
        )
        if usesSplitNavigation {
            Button {
                selectedEntryID = entry.id
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: entry.id) {
                row
            }
            .buttonStyle(.plain)
        }
    }

    private var headerActions: some View {
        Button {
            importError = nil
            showingImporter = true
        } label: {
            Label(
                model.lifeList.isEmpty ? "Import eBird life list CSV" : "Replace from eBird CSV",
                systemImage: "square.and.arrow.down"
            )
        }
        .buttonStyle(GuideChipStyle(selected: true))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No life list yet")
                .font(.system(.title2, design: .serif))
                .foregroundStyle(GuideColor.green)
            Text(emptyStateHelp)
            .font(.body)
            .foregroundStyle(GuideColor.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var listFooterHelp: String {
        let attach = UserPhotoImport.supportsPaste
            ? "Attach multiple photos from your library on each bird, or paste images copied from Photos (resized before saving)."
            : "Attach multiple photos from your library on each bird, or drag and drop them onto the detail."
        return "Import an eBird Life List CSV (Sightings Lists → Download) or My Data for the latest record date and place. \(attach) Photos are badged My photo or Stock. The list and photos sync via iCloud Birdlists when signed in."
    }

    private var emptyStateHelp: String {
        let attach = UserPhotoImport.supportsPaste
            ? "Attach multiple photos from your library or paste images copied from Photos (resized before saving)"
            : "Attach multiple photos from your library or drag and drop them onto the detail"
        return "Download your life list from eBird (My eBird → Sightings Lists → Download) and import the CSV. Each species shows a Latest Record date and place from the import. \(attach); those are badged My photo, while Field Guide images show as Stock."
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("Search name or place", text: $searchDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchDraft.isEmpty {
                Button {
                    searchDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(GuideColor.muted)
                }
                .accessibilityLabel("Clear search")
            }
        }
    }

    /// Drop the split selection when the filtered list no longer contains it.
    private func clearStaleSelection() {
        guard let selectedEntryID else { return }
        if !filteredEntries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
            importMessage = nil
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let parsed = try EBirdLifeListCSVParser.parse(
                    data: data,
                    sourceFileName: url.lastPathComponent
                )
                let doc = model.lifeList.replace(from: parsed)
                let withLatest = doc.entries.filter(\.hasFirstRecorded).count
                if parsed.aggregatedFromMyData {
                    importMessage = "Imported \(doc.entries.count) species from My Data (\(withLatest) with a Latest Record)."
                } else {
                    importMessage = "Imported \(doc.entries.count) countable species from \(parsed.sourceFileName) (\(withLatest) with a Latest Record)."
                }
                importError = nil
                selectedCountryCode = Self.globalCountrySentinel
                selectedEntryID = nil
                path = NavigationPath()
            } catch {
                importError = error.localizedDescription
                importMessage = nil
            }
        }
    }
}

// MARK: - Row (Field Guide list layout + recorded fields)

private struct LifeListRow: View {
    var entry: LifeListEntry
    var guideSpecies: Species?
    var photoRevision: Int
    var isSelected: Bool = false

    private static let listThumbMaxPixels: CGFloat = 270

    var body: some View {
        let photoPath = rowPhotoPath
        let source = rowPhotoSource
        return HStack(alignment: .center, spacing: 12) {
            Group {
                if let photoPath {
                    ZStack(alignment: .bottomLeading) {
                        BundlePhoto(
                            path: photoPath,
                            alt: "",
                            fills: true,
                            maxPixelSize: Self.listThumbMaxPixels
                        )
                        .frame(width: 88, height: 64)
                        .clipped()

                        if let source {
                            PhotoSourceBadge(source: source, compact: true)
                                .padding(4)
                        }
                    }
                } else {
                    GuideColor.green.opacity(0.12)
                        .frame(width: 88, height: 64)
                }
            }
            .frame(width: 92, height: 64, alignment: .leading)
            .accessibilityHidden(true)
            .id("\(entry.id)-\(photoRevision)-\(photoPath ?? "")-\(source?.rawValue ?? "none")")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.commonName)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(GuideColor.ink)
                Text(entry.displayScientificName)
                    .font(.subheadline.italic())
                    .foregroundStyle(GuideColor.muted)

                if let latest = entry.firstRecordedLine {
                    recordedLabel(title: "Latest Record", value: latest)
                } else {
                    Text("No recorded date or location in the import")
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isSelected ? 8 : 0)
        .padding(.vertical, 10)
        .background(isSelected ? GuideColor.green.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GuideColor.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Opens life list details and photos")
        .accessibilityValue(source?.accessibilityLabel ?? "")
    }

    private func recordedLabel(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GuideColor.green)
            Text(value)
                .font(.caption)
                .foregroundStyle(GuideColor.muted)
                .lineLimit(2)
        }
        .padding(.top, 2)
    }

    private var rowPhotoPath: String? {
        if let path = entry.resolvedLibraryPhotos.first(where: { BundleImages.url(for: $0.path) != nil })?.path {
            return path
        }
        if let species = guideSpecies {
            let order = ["male": 0, "female": 1, "either": 2, "unsexed": 3, "illustration": 4]
            let sorted = species.photos.sorted {
                (order[$0.role] ?? 9, $0.label) < (order[$1.role] ?? 9, $1.label)
            }
            return sorted.first?.src
        }
        return nil
    }

    private var rowPhotoSource: LifeListPhotoSource? {
        if entry.resolvedLibraryPhotos.contains(where: { BundleImages.url(for: $0.path) != nil }) {
            return entry.resolvedLibraryPhotoSource ?? .library
        }
        if rowPhotoPath != nil {
            return .stock
        }
        return nil
    }
}

// MARK: - Display photo (library attach or Field Guide stock)

private struct LifeListDisplayPhoto: Identifiable, Hashable {
    var id: String
    var path: String
    var source: LifeListPhotoSource
    /// Non-nil only for removable library attaches.
    var libraryPhotoID: String?
    var caption: String?

    var isLibrary: Bool { source == .library }
}

// MARK: - Detail + Photos library

private struct LifeListDetailView: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var entryID: String

    /// Multi-select from Photos; each pick is appended to the species gallery.
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photoError: String?
    /// Library photo focused for the shared Remove action (prefs: Remove on same row as Add).
    @State private var selectedLibraryPhotoID: String?
    @State private var isPhotoDropTargeted = false
    /// Presented when the user chooses among multiple library photos to remove.
    @State private var removeLibraryRequest: RemoveLibraryPhotoRequest?

    private var entry: LifeListEntry? {
        model.lifeList.entry(id: entryID)
    }

    /// Chrome below/above the hero photo (header, scientific, latest record on phone, badge, caption, actions, padding).
    private var reservedChromeHeight: CGFloat {
        // iPad/Mac: name + Latest Record share one line. iPhone: Latest Record stacks under scientific name.
        horizontalSizeClass == .regular ? 220 : 280
    }

    private var minimumPhotoHeight: CGFloat {
        horizontalSizeClass == .regular ? 360 : 260
    }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if let entry {
                GeometryReader { geo in
                    let displayPhotos = displayPhotos(for: entry)
                    let photoHeight = photoHeight(
                        for: geo.size.height,
                        photoCount: max(displayPhotos.count, 1)
                    )
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            detailHeader(for: entry)

                            photoGallery(for: entry, displayPhotos: displayPhotos, photoHeight: photoHeight)

                            if let photoError {
                                Text(photoError)
                                    .font(.footnote)
                                    .foregroundStyle(GuideColor.rust)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: geo.size.height, alignment: .topLeading)
                        .userPhotoDrop(isTargeted: $isPhotoDropTargeted) { jpegs in
                            importDroppedJPEGs(jpegs)
                        }
                        .accessibilityHint(
                            UserPhotoImport.supportsPaste
                                ? "Paste photos copied from Photos to add them to this life list bird"
                                : "Drop photos here to add them to this life list bird"
                        )
                    }
                }
                .guideBackground()
                // Content owns the name (and Latest Record placement); keep nav title empty.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    syncSelectedLibraryPhoto(for: entry)
                }
                .onChange(of: model.lifeList.photoRevision) { _, _ in
                    if let current = model.lifeList.entry(id: entryID) {
                        syncSelectedLibraryPhoto(for: current)
                    }
                }
                .sheet(item: $removeLibraryRequest) { request in
                    RemoveLibraryPhotoSheet(
                        photos: request.photos,
                        initiallySelectedID: request.initiallySelectedID
                    ) { selectedID in
                        model.lifeList.removePhoto(id: selectedID, from: entryID)
                        photoError = nil
                        removeLibraryRequest = nil
                        if let next = model.lifeList.entry(id: entryID) {
                            syncSelectedLibraryPhoto(for: next)
                        } else {
                            selectedLibraryPhotoID = nil
                        }
                    } onCancel: {
                        removeLibraryRequest = nil
                    }
                }
            } else {
                Text("That bird is not on your life list.")
                    .guideBackground()
            }
        }
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await importPhotos(from: newItems) }
        }
    }

    /// iPad/Mac: name + Latest Record on one top line, scientific below.
    /// iPhone: common name, scientific name, then Latest Record under the scientific name.
    @ViewBuilder
    private func detailHeader(for entry: LifeListEntry) -> some View {
        if isRegularWidth {
            detailTitleRow(for: entry)
            Text(entry.displayScientificName)
                .font(.title3.italic())
                .foregroundStyle(GuideColor.muted)
        } else {
            Text(entry.commonName)
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(GuideColor.green)

            Text(entry.displayScientificName)
                .font(.title3.italic())
                .foregroundStyle(GuideColor.muted)

            latestRecordBlock(for: entry, alignment: .leading)
        }
    }

    @ViewBuilder
    private func photoGallery(
        for entry: LifeListEntry,
        displayPhotos: [LifeListDisplayPhoto],
        photoHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if displayPhotos.isEmpty {
                GuideColor.green.opacity(isPhotoDropTargeted ? 0.18 : 0.10)
                    .frame(maxWidth: .infinity)
                    .frame(height: photoHeight)
                    .overlay {
                        VStack(spacing: 6) {
                            Text(isPhotoDropTargeted ? "Drop to add your photo" : "No photo yet")
                                .font(.subheadline)
                                .foregroundStyle(GuideColor.muted)
                            Text(emptyPhotoHint)
                                .font(.caption)
                                .foregroundStyle(GuideColor.muted)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                    }
                    .overlay {
                        if isPhotoDropTargeted {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(GuideColor.green, lineWidth: 3)
                        }
                    }
            } else if isRegularWidth && displayPhotos.count >= 2 {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(displayPhotos) { photo in
                        photoCard(photo, entry: entry, photoHeight: photoHeight)
                    }
                }
            } else {
                ForEach(displayPhotos) { photo in
                    photoCard(photo, entry: entry, photoHeight: photoHeight)
                }
            }

            photoActionsRow(for: entry)
        }
    }

    @ViewBuilder
    private func photoCard(
        _ photo: LifeListDisplayPhoto,
        entry: LifeListEntry,
        photoHeight: CGFloat
    ) -> some View {
        let libraryCount = entry.resolvedLibraryPhotos
            .filter { BundleImages.url(for: $0.path) != nil }
            .count
        let isSelectedLibrary = photo.libraryPhotoID != nil
            && photo.libraryPhotoID == selectedLibraryPhotoID

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let caption = photo.caption {
                    Text(caption)
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(GuideColor.green)
                } else if isSelectedLibrary, libraryCount > 1 {
                    Text("Selected to remove")
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(GuideColor.green)
                }
                Spacer(minLength: 0)
                PhotoSourceBadge(source: photo.source)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let libraryID = photo.libraryPhotoID {
                    selectedLibraryPhotoID = libraryID
                }
            }
            .accessibilityAddTraits(photo.isLibrary ? .isButton : [])
            .accessibilityHint(
                photo.isLibrary
                    ? (libraryCount > 1
                        ? "Selects this library photo; use Remove a photo to choose which to delete"
                        : "Selects this library photo for Remove")
                    : ""
            )

            ZoomablePhoto(
                path: photo.path,
                alt: entry.commonName,
                label: entry.commonName,
                cacheRevision: model.lifeList.photoRevision,
                prefersLargerRegularHeight: true,
                preferredHeight: photoHeight
            )
            .id("\(photo.id)-\(model.lifeList.photoRevision)-\(Int(photoHeight))")
            .overlay {
                if isSelectedLibrary {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(GuideColor.green.opacity(0.55), lineWidth: 2)
                }
            }

            Text(photoHelpCaption(isLibrary: photo.isLibrary, multiLibrary: libraryCount > 1))
            .font(.caption)
            .foregroundStyle(GuideColor.muted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelectedLibrary ? [.isSelected] : [])
    }

    private var emptyPhotoHint: String {
        if UserPhotoImport.supportsPaste {
            return "Add from your library or paste a photo copied from Photos. Pasted images are resized before saving."
        }
        return "Add from your library or drag and drop photos here."
    }

    private func photoHelpCaption(isLibrary: Bool, multiLibrary: Bool) -> String {
        let selectHint = multiLibrary && isLibrary
            ? " Tap the My photo badge to preselect; Remove a photo lets you choose which to delete."
            : ""
        if UserPhotoImport.supportsPaste {
            return isLibrary
                ? "Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view. Paste more photos from Photos to add them — images are resized before saving.\(selectHint)"
                : "Field Guide open-licence photo — add your own from the library below, or paste a photo copied from Photos. Pinch or double-tap to zoom; long-press for full screen."
        }
        return isLibrary
            ? "Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view. Drop more photos onto this page to add them.\(selectHint)"
            : "Field Guide open-licence photo — add your own from the library below, or drag and drop photos onto this page. Pinch or double-tap to zoom; long-press for full screen."
    }

    @ViewBuilder
    private func photoActionsRow(for entry: LifeListEntry) -> some View {
        let libraryPhotos = entry.resolvedLibraryPhotos.filter { BundleImages.url(for: $0.path) != nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: 12,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Add photo from library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(GuideChipStyle(selected: true))
                .accessibilityHint(
                    UserPhotoImport.supportsPaste
                        ? "Also paste a photo copied from Photos"
                        : "Also accepts drag and drop onto the photo area"
                )

                if !libraryPhotos.isEmpty {
                    Button {
                        presentRemoveLibraryPhoto(from: entry)
                    } label: {
                        Label(
                            libraryPhotos.count > 1 ? "Remove a photo…" : "Remove photo",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(GuideChipStyle(selected: false))
                    .accessibilityHint(
                        libraryPhotos.count > 1
                            ? "Choose which library photo to remove. Tap a My photo badge to preselect."
                            : "Removes your library photo"
                    )
                }

                Spacer(minLength: 0)
            }

            if UserPhotoImport.supportsPaste {
                UserPhotoPasteChip(expanding: false) { jpegs in
                    importPastedJPEGs(jpegs)
                } onEmpty: {
                    photoError = "Copy a photo in Photos first, then paste it here."
                }
            }
        }
    }

    /// Regular-width only: bird name and Latest Record share the top content line.
    @ViewBuilder
    private func detailTitleRow(for entry: LifeListEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.commonName)
                .font(.system(size: 34, weight: .regular, design: .serif))
                .foregroundStyle(GuideColor.green)
                .layoutPriority(1)

            Spacer(minLength: 8)

            latestRecordBlock(for: entry, alignment: .trailing)
                .frame(maxWidth: 320, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func latestRecordBlock(
        for entry: LifeListEntry,
        alignment: HorizontalAlignment
    ) -> some View {
        if let latest = entry.firstRecordedLine {
            VStack(alignment: alignment, spacing: 2) {
                Text("Latest Record".uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(GuideColor.muted)
                Text(latest)
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.ink)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Latest Record, \(latest)")
        }
    }

    /// Library attaches first, then Field Guide stock photos (male / female / etc.).
    private func displayPhotos(for entry: LifeListEntry) -> [LifeListDisplayPhoto] {
        var items: [LifeListDisplayPhoto] = []
        for photo in entry.resolvedLibraryPhotos {
            guard BundleImages.url(for: photo.path) != nil else { continue }
            items.append(
                LifeListDisplayPhoto(
                    id: "library-\(photo.id)",
                    path: photo.path,
                    source: .library,
                    libraryPhotoID: photo.id,
                    caption: nil
                )
            )
        }
        for stock in guideStockPhotos(for: entry) {
            items.append(stock)
        }
        return items
    }

    private func guideStockPhotos(for entry: LifeListEntry) -> [LifeListDisplayPhoto] {
        guard let species = model.catalog?.species(forCommonName: entry.commonName) else { return [] }
        let order = ["male": 0, "female": 1, "either": 2, "unsexed": 3, "illustration": 4]
        let sorted = species.photos.sorted {
            (order[$0.role] ?? 9, $0.label) < (order[$1.role] ?? 9, $1.label)
        }
        return sorted.compactMap { photo -> LifeListDisplayPhoto? in
            guard BundleImages.url(for: photo.src) != nil else { return nil }
            let caption: String?
            switch photo.role {
            case "male": caption = "Male"
            case "female": caption = "Female"
            case "illustration": caption = "Illustration"
            default: caption = nil
            }
            return LifeListDisplayPhoto(
                id: "stock-\(species.id)-\(photo.src)",
                path: photo.src,
                source: .stock,
                libraryPhotoID: nil,
                caption: caption
            )
        }
    }

    private func photoHeight(for availableHeight: CGFloat, photoCount: Int) -> CGFloat {
        let full = max(minimumPhotoHeight, availableHeight - reservedChromeHeight)
        guard photoCount > 1 else { return full }
        // Keep multi-photo cards readable without stacking several full-pane heroes.
        let shared = full * (isRegularWidth ? 0.72 : 0.85)
        return max(minimumPhotoHeight * 0.85, shared)
    }

    private func syncSelectedLibraryPhoto(for entry: LifeListEntry) {
        let ids = entry.resolvedLibraryPhotos
            .filter { BundleImages.url(for: $0.path) != nil }
            .map(\.id)
        if let selectedLibraryPhotoID, ids.contains(selectedLibraryPhotoID) {
            return
        }
        selectedLibraryPhotoID = ids.first
    }

    private func presentRemoveLibraryPhoto(from entry: LifeListEntry) {
        let library = entry.resolvedLibraryPhotos.filter { BundleImages.url(for: $0.path) != nil }
        guard !library.isEmpty else { return }
        if library.count == 1, let only = library.first {
            model.lifeList.removePhoto(id: only.id, from: entry.id)
            photoError = nil
            selectedLibraryPhotoID = nil
            return
        }
        let candidates: [RemovableLibraryPhoto] = library.enumerated().map { index, photo in
            RemovableLibraryPhoto(
                id: photo.id,
                path: photo.path,
                title: "My photo \(index + 1)"
            )
        }
        let initial = selectedLibraryPhotoID
            ?? candidates.first?.id
        removeLibraryRequest = RemoveLibraryPhotoRequest(
            photos: candidates,
            initiallySelectedID: initial
        )
    }

    @MainActor
    private func importPhotos(from items: [PhotosPickerItem]) async {
        photoError = nil
        var failures = 0
        var lastAddedID: String?
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let jpeg = UserPhotoImport.jpeg(from: data)?.data else {
                    failures += 1
                    continue
                }
                let attached = try model.lifeList.addPhoto(jpegData: jpeg, for: entryID)
                lastAddedID = attached.id
            } catch {
                failures += 1
                photoError = error.localizedDescription
            }
        }
        finishImport(lastAddedID: lastAddedID, failures: failures, attempted: items.count)
        pickerItems = []
    }

    @MainActor
    private func importDroppedJPEGs(_ jpegs: [Data]) {
        importEncodedJPEGs(
            jpegs,
            emptyMessage: "That drop could not be read. Try a JPEG or PNG, or use Add photo from library."
        )
    }

    @MainActor
    private func importPastedJPEGs(_ jpegs: [Data]) {
        importEncodedJPEGs(
            jpegs,
            emptyMessage: "Copy a photo in Photos first, then paste it here."
        )
    }

    /// Drop / paste pipelines already downscale and encode JPEG.
    @MainActor
    private func importEncodedJPEGs(_ jpegs: [Data], emptyMessage: String) {
        photoError = nil
        guard !jpegs.isEmpty else {
            photoError = emptyMessage
            return
        }
        var failures = 0
        var lastAddedID: String?
        for jpeg in jpegs {
            do {
                let attached = try model.lifeList.addPhoto(jpegData: jpeg, for: entryID)
                lastAddedID = attached.id
            } catch {
                failures += 1
                photoError = error.localizedDescription
            }
        }
        finishImport(lastAddedID: lastAddedID, failures: failures, attempted: jpegs.count)
    }

    private func finishImport(lastAddedID: String?, failures: Int, attempted: Int) {
        if let lastAddedID {
            selectedLibraryPhotoID = lastAddedID
        }
        if failures > 0 && photoError == nil {
            let allFailedFallback = UserPhotoImport.supportsPaste
                ? "Those photos could not be read. Try other images from your library, or paste a photo copied from Photos."
                : "Those photos could not be read. Try other images from your library, or drop a JPEG or PNG."
            photoError = failures == attempted
                ? allFailedFallback
                : "Some photos could not be read. The rest were added."
        }
    }
}
