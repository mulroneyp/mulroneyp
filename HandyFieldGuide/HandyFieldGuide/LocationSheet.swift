import SwiftUI
import UniformTypeIdentifiers

struct LocationSheet: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var showingImporter: Bool
    @State private var importError: String?
    @State private var locationPendingRename: ImportedLocationRecord?
    @State private var renameText = ""
    @State private var locationPendingDelete: ImportedLocationRecord?

    private let startInImportMode: Bool

    init(current: String, startInImportMode: Bool = false) {
        _draft = State(initialValue: current)
        self.startInImportMode = startInImportMode
        _showingImporter = State(initialValue: startInImportMode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(startInImportMode
                         ? "Add a new area from an eBird Frequency / barchart `.txt` export (tab-separated, four week columns per month). The app names the place from the location id in the filename when it can (for example L436229)."
                         : "Rename or delete saved eBird imports here. Bundled curated presets (Monteverde, Melbourne, and the district shortcuts) stay in the Location menu and are not removed.")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if startInImportMode {
                        importSection
                    }

                    if !model.imports.locations.isEmpty {
                        importedSection
                    } else if !startInImportMode {
                        Text("No saved imports yet. Use Add eBird barchart on the Location menu to add one.")
                            .font(.subheadline)
                            .foregroundStyle(GuideColor.muted)
                    }

                    if !startInImportMode {
                        TextField("Place", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(apply)

                        Button("Use this place", action: apply)
                            .buttonStyle(GuideChipStyle(selected: true))
                    }
                }
                .padding(20)
            }
            .guideBackground()
            .navigationTitle(startInImportMode ? "Add location" : "Manage locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.plainText, .tabSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .sheet(item: $locationPendingRename) { location in
                renameSheet(for: location)
            }
            .alert(
                deleteAlertTitle,
                isPresented: Binding(
                    get: { locationPendingDelete != nil },
                    set: { if !$0 { locationPendingDelete = nil } }
                ),
                presenting: locationPendingDelete
            ) { location in
                Button("Delete", role: .destructive) {
                    model.deleteImportedLocation(location.id)
                    if LocationResolver.normalize(draft) == LocationResolver.normalize(location.name) {
                        draft = model.locationQuery
                    }
                    locationPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    locationPendingDelete = nil
                }
            } message: { location in
                Text("Remove “\(location.name)” from Handy Field Guide? This only deletes your saved import. Curated presets and the bundled sample file stay available to re-import.")
            }
        }
    }

    private var deleteAlertTitle: String {
        if let locationPendingDelete {
            return "Delete \(locationPendingDelete.name)?"
        }
        return "Delete location?"
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EBIRD BARCHART")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            Button {
                importError = nil
                showingImporter = true
            } label: {
                Label("Import barchart .txt", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(GuideChipStyle(selected: false))

            Button {
                do {
                    try model.importBundledSample()
                    draft = model.locationQuery
                    dismiss()
                } catch {
                    importError = error.localizedDescription
                }
            } label: {
                Label("Add sample L436229", systemImage: "doc.text")
            }
            .buttonStyle(GuideChipStyle(selected: false))

            if let importError {
                Text(importError)
                    .font(.footnote)
                    .foregroundStyle(GuideColor.rust)
            }
            if let message = model.importMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(GuideColor.green)
            }
        }
    }

    private var importedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVED IMPORTS")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            ForEach(model.imports.locations) { location in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        draft = location.name
                        model.locationQuery = location.name
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.name)
                                .font(.body.weight(.semibold))
                            Text("\(location.species.count) taxa · \(location.placeTitle)")
                                .font(.caption)
                                .foregroundStyle(GuideColor.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(GuideColor.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(GuideColor.green.opacity(0.4), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 12) {
                        Button("Rename") {
                            renameText = location.name
                            locationPendingRename = location
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GuideColor.green)

                        Button("Delete", role: .destructive) {
                            locationPendingDelete = location
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func renameSheet(for location: ImportedLocationRecord) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a name for this saved area. The eBird location id stays the same.")
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Location name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { saveRename(location) }

                Spacer()
            }
            .padding(20)
            .guideBackground()
            .navigationTitle("Rename location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { locationPendingRename = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveRename(location) }
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveRename(_ location: ImportedLocationRecord) {
        let previous = location.name
        model.renameImportedLocation(location.id, to: renameText)
        if let updated = model.imports.locations.first(where: { $0.id == location.id }) {
            if LocationResolver.normalize(draft) == LocationResolver.normalize(previous) {
                draft = updated.name
            }
        }
        locationPendingRename = nil
    }

    private func apply() {
        model.locationQuery = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                try model.importBarchart(data: data, sourceFileName: url.lastPathComponent, displayName: nil)
                draft = model.locationQuery
                dismiss()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

struct GuideChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .foregroundStyle(selected ? GuideColor.paper : GuideColor.green)
            .background(selected ? GuideColor.green : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(GuideColor.green, lineWidth: 1.5)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
