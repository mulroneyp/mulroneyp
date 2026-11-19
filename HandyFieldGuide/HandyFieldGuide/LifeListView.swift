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
                    } else {
                        ForEach(filteredEntries) { entry in
                            entryRowLink(entry: entry)
                        }
                    }

                        Text(
                            "Import an eBird Life List CSV (Sightings Lists → Download) or My Data for the latest record date and place. Attach a photo from your library on each bird. Photos are badged My photo or Stock. The list and photos sync via iCloud Birdlists when signed in."
                        )
                    .font(.footnote)
                    .foregroundStyle(GuideColor.muted)
                    .padding(.top, 8)
                }
            }
            .padding(16)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
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
            Text(
                "Download your life list from eBird (My eBird → Sightings Lists → Download) and import the CSV. Each species shows a Latest Record date and place from the import. Attach your own photos from the library; those are badged My photo, while Field Guide images show as Stock."
            )
            .font(.body)
            .foregroundStyle(GuideColor.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
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
                            LifeListPhotoSourceBadge(source: source, compact: true)
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
        .accessibilityHint("Opens life list details and photo")
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
        if let path = entry.localPhotoPath, BundleImages.url(for: path) != nil {
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
        if let path = entry.localPhotoPath, BundleImages.url(for: path) != nil {
            return entry.resolvedLibraryPhotoSource ?? .library
        }
        if rowPhotoPath != nil {
            return .stock
        }
        return nil
    }
}

/// Compact badge for Life List photo origin (library vs Field Guide open-licence stock).
private struct LifeListPhotoSourceBadge: View {
    var source: LifeListPhotoSource
    var compact: Bool = false

    var body: some View {
        Text(source.badgeTitle)
            .font(compact ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold))
            .tracking(compact ? 0.2 : 0.5)
            .foregroundStyle(GuideColor.green)
            .padding(.horizontal, compact ? 5 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(GuideColor.card.opacity(compact ? 0.92 : 1))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(GuideColor.green.opacity(0.35), lineWidth: 1)
            }
            .accessibilityLabel(source.accessibilityLabel)
    }
}

// MARK: - Detail + Photos library

private struct LifeListDetailView: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var entryID: String

    @State private var pickerItem: PhotosPickerItem?
    @State private var photoError: String?

    private var entry: LifeListEntry? {
        model.lifeList.entry(id: entryID)
    }

    /// Chrome below/above the hero photo (titles, badge, caption, record, actions, padding).
    private var reservedChromeHeight: CGFloat {
        horizontalSizeClass == .regular ? 250 : 280
    }

    private var minimumPhotoHeight: CGFloat {
        horizontalSizeClass == .regular ? 360 : 260
    }

    var body: some View {
        Group {
            if let entry {
                GeometryReader { geo in
                    let photoHeight = max(minimumPhotoHeight, geo.size.height - reservedChromeHeight)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.commonName)
                                .font(.system(size: horizontalSizeClass == .regular ? 34 : 28, weight: .regular, design: .serif))
                                .foregroundStyle(GuideColor.green)
                            Text(entry.displayScientificName)
                                .font(.title3.italic())
                                .foregroundStyle(GuideColor.muted)

                            photoBlock(for: entry, photoHeight: photoHeight)

                            recordedSection(
                                title: "Latest Record",
                                date: entry.firstRecordedDate,
                                location: entry.firstRecordedLocation
                            )

                            if let photoError {
                                Text(photoError)
                                    .font(.footnote)
                                    .foregroundStyle(GuideColor.rust)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                .guideBackground()
                .navigationTitle(entry.commonName)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                Text("That bird is not on your life list.")
                    .guideBackground()
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await importPhoto(from: newItem) }
        }
    }

    @ViewBuilder
    private func photoBlock(for entry: LifeListEntry, photoHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = entry.localPhotoPath, BundleImages.url(for: path) != nil {
                photoSourceHeader(source: entry.resolvedLibraryPhotoSource ?? .library)

                ZoomablePhoto(
                    path: path,
                    alt: entry.commonName,
                    label: entry.commonName,
                    cacheRevision: model.lifeList.photoRevision,
                    prefersLargerRegularHeight: true,
                    preferredHeight: photoHeight
                )
                .id("\(path)-\(model.lifeList.photoRevision)-\(Int(photoHeight))")

                Text("Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view.")
                    .font(.caption)
                    .foregroundStyle(GuideColor.muted)
            } else if let fallback = guideFallbackPhotoPath(for: entry) {
                // Prefer the user's attached photo; otherwise show the Field Guide
                // species image so the split detail still has a large visual.
                photoSourceHeader(source: .stock)

                ZoomablePhoto(
                    path: fallback,
                    alt: entry.commonName,
                    label: entry.commonName,
                    cacheRevision: model.lifeList.photoRevision,
                    prefersLargerRegularHeight: true,
                    preferredHeight: photoHeight
                )
                .id("guide-\(fallback)-\(model.lifeList.photoRevision)-\(Int(photoHeight))")

                Text("Field Guide open-licence photo — attach your own from the library below. Pinch or double-tap to zoom; long-press for full screen.")
                    .font(.caption)
                    .foregroundStyle(GuideColor.muted)
            } else {
                GuideColor.green.opacity(0.10)
                    .frame(maxWidth: .infinity)
                    .frame(height: photoHeight)
                    .overlay {
                        Text("No photo yet")
                            .font(.subheadline)
                            .foregroundStyle(GuideColor.muted)
                    }
            }

            PhotosPicker(
                selection: $pickerItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label(
                    entry.localPhotoPath == nil ? "Add photo from library" : "Replace photo from library",
                    systemImage: "photo.on.rectangle"
                )
            }
            .buttonStyle(GuideChipStyle(selected: true))

            if entry.localPhotoPath != nil {
                Button {
                    model.lifeList.clearPhoto(for: entry.id)
                    photoError = nil
                } label: {
                    Label("Remove photo", systemImage: "trash")
                }
                .buttonStyle(GuideChipStyle(selected: false))
            }
        }
    }

    private func photoSourceHeader(source: LifeListPhotoSource) -> some View {
        HStack {
            Spacer(minLength: 0)
            LifeListPhotoSourceBadge(source: source)
        }
    }

    private func guideFallbackPhotoPath(for entry: LifeListEntry) -> String? {
        guard let species = model.catalog?.species(forCommonName: entry.commonName) else { return nil }
        let order = ["male": 0, "female": 1, "either": 2, "unsexed": 3, "illustration": 4]
        let sorted = species.photos.sorted {
            (order[$0.role] ?? 9, $0.label) < (order[$1.role] ?? 9, $1.label)
        }
        guard let src = sorted.first?.src, BundleImages.url(for: src) != nil else { return nil }
        return src
    }

    @ViewBuilder
    private func recordedSection(title: String, date: String?, location: String?) -> some View {
        let line = LifeListEntry.recordedLine(date: date, location: location)
        if let line {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(GuideColor.muted)
                Text(line)
                    .font(.body)
                    .foregroundStyle(GuideColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func importPhoto(from item: PhotosPickerItem) async {
        photoError = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.88) else {
                photoError = "That photo could not be read. Try another image from your library."
                pickerItem = nil
                return
            }
            _ = try model.lifeList.setPhoto(jpegData: jpeg, for: entryID)
            pickerItem = nil
        } catch {
            photoError = error.localizedDescription
            pickerItem = nil
        }
    }
}
