import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Full-screen Life List peer to the Field Guide home: same overall list format,
/// with Country / Map / Bird Count Total / Field Guide in the header chrome.
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
    @State private var path = NavigationPath()
    /// Empty string means Global; otherwise an ISO country code.
    @State private var selectedCountryCode: String = Self.globalCountrySentinel

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 520 : 720
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
        NavigationStack(path: $path) {
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
                                NavigationLink(value: entry.id) {
                                    LifeListRow(
                                        entry: entry,
                                        guideSpecies: model.catalog?.species(forCommonName: entry.commonName),
                                        photoRevision: model.lifeList.photoRevision
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(
                            "Import an eBird Life List CSV (Sightings Lists → Download) or My Data for first and last recorded dates. Attach a photo from your library on each bird. The list and photos sync via iCloud Birdlists when signed in."
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
            .navigationDestination(for: String.self) { entryID in
                if let entry = model.lifeList.entry(id: entryID) {
                    LifeListDetailView(entryID: entry.id)
                } else {
                    Text("That bird is not on your life list.")
                        .guideBackground()
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
                "Download your life list from eBird (My eBird → Sightings Lists → Download) and import the CSV. Use My Data if you want both first and last recorded dates in one file. Classic life-list exports fill First Recorded; My Data (or Last Date / Last Location columns) fills Last Recorded."
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
                let withLast = doc.entries.filter(\.hasLastRecorded).count
                let withFirst = doc.entries.filter(\.hasFirstRecorded).count
                if parsed.aggregatedFromMyData {
                    importMessage = "Imported \(doc.entries.count) species from My Data (\(withFirst) with first recorded, \(withLast) with last recorded)."
                } else {
                    importMessage = "Imported \(doc.entries.count) countable species from \(parsed.sourceFileName) (\(withFirst) first recorded; \(withLast) last recorded)."
                }
                importError = nil
                selectedCountryCode = Self.globalCountrySentinel
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

    private static let listThumbMaxPixels: CGFloat = 270

    var body: some View {
        let photoPath = rowPhotoPath
        return HStack(alignment: .center, spacing: 12) {
            Group {
                if let photoPath {
                    BundlePhoto(
                        path: photoPath,
                        alt: "",
                        fills: true,
                        maxPixelSize: Self.listThumbMaxPixels
                    )
                    .frame(width: 88, height: 64)
                    .clipped()
                } else {
                    GuideColor.green.opacity(0.12)
                        .frame(width: 88, height: 64)
                }
            }
            .frame(width: 92, height: 64, alignment: .leading)
            .accessibilityHidden(true)
            .id("\(entry.id)-\(photoRevision)-\(photoPath ?? "")")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.commonName)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(GuideColor.ink)
                Text(entry.displayScientificName)
                    .font(.subheadline.italic())
                    .foregroundStyle(GuideColor.muted)

                if let last = entry.lastRecordedLine {
                    recordedLabel(title: "Last recorded", value: last)
                }
                if let first = entry.firstRecordedLine {
                    recordedLabel(title: "First recorded", value: first)
                }
                if !entry.hasFirstRecorded && !entry.hasLastRecorded {
                    Text("No recorded date or location in the import")
                        .font(.caption)
                        .foregroundStyle(GuideColor.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GuideColor.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens life list details and photo")
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
}

// MARK: - Detail + Photos library

private struct LifeListDetailView: View {
    @EnvironmentObject private var model: GuideModel
    var entryID: String

    @State private var pickerItem: PhotosPickerItem?
    @State private var photoError: String?

    private var entry: LifeListEntry? {
        model.lifeList.entry(id: entryID)
    }

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(entry.commonName)
                            .font(.system(.title, design: .serif))
                            .foregroundStyle(GuideColor.green)
                        Text(entry.displayScientificName)
                            .font(.title3.italic())
                            .foregroundStyle(GuideColor.muted)

                        photoBlock(for: entry)

                        recordedSection(
                            title: "Last recorded",
                            date: entry.lastRecordedDate,
                            location: entry.lastRecordedLocation
                        )
                        recordedSection(
                            title: "First recorded",
                            date: entry.firstRecordedDate,
                            location: entry.firstRecordedLocation
                        )

                        if let photoError {
                            Text(photoError)
                                .font(.footnote)
                                .foregroundStyle(GuideColor.rust)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    private func photoBlock(for entry: LifeListEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = entry.localPhotoPath, BundleImages.url(for: path) != nil {
                ZoomablePhoto(
                    path: path,
                    alt: entry.commonName,
                    label: entry.commonName,
                    cacheRevision: model.lifeList.photoRevision
                )
                .id("\(path)-\(model.lifeList.photoRevision)")

                Text("Pinch or double-tap to zoom; drag to pan. Long-press for a full-screen view.")
                    .font(.caption)
                    .foregroundStyle(GuideColor.muted)
            } else {
                GuideColor.green.opacity(0.10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
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
