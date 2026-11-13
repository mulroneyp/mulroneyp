import SwiftUI
import UniformTypeIdentifiers

struct LocationSheet: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var showingAPIImporter = false
    @State private var importError: String?
    @State private var locationPendingRename: ImportedLocationRecord?
    @State private var renameText = ""
    @State private var locationPendingDelete: ImportedLocationRecord?
    @State private var showingMergeLists = false
    @State private var dismissAfterMerge = false
    @State private var dismissAfterAPIImport = false

    private let startInImportMode: Bool

    init(startInImportMode: Bool = false) {
        self.startInImportMode = startInImportMode
        // Prefer the chooser (API vs .txt) — do not auto-open the file picker.
        _showingImporter = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(startInImportMode
                         ? "Add a new area via the eBird API (search hotspots, pull frequency) or by importing a Frequency / barchart `.txt` export. Only imported locations appear in the Location menu."
                         : "Rename or delete saved eBird imports. Merge nearby hotspot lists into a new named area. Only imported locations appear in the Location menu.")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if startInImportMode {
                        importSection
                    }

                    if !startInImportMode, model.imports.locations.count >= 2 {
                        Button {
                            showingMergeLists = true
                        } label: {
                            Label("Merge lists", systemImage: "arrow.triangle.merge")
                        }
                        .buttonStyle(GuideChipStyle(selected: false))
                    }

                    if !model.imports.locations.isEmpty {
                        importedSection
                    } else if !startInImportMode {
                        Text("No saved imports yet. Use Add location to import via eBird API or a barchart .txt.")
                            .font(.subheadline)
                            .foregroundStyle(GuideColor.muted)

                        Button {
                            importError = nil
                            showingAPIImporter = true
                        } label: {
                            Label("Add location", systemImage: "plus")
                        }
                        .buttonStyle(GuideChipStyle(selected: true))
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .sheet(isPresented: $showingAPIImporter, onDismiss: {
                if dismissAfterAPIImport {
                    dismissAfterAPIImport = false
                    dismiss()
                }
            }) {
                EBirdAPIImportSheet(onImported: { dismissAfterAPIImport = true })
                    .environmentObject(model)
            }
            .sheet(item: $locationPendingRename) { location in
                renameSheet(for: location)
            }
            .sheet(isPresented: $showingMergeLists, onDismiss: {
                if dismissAfterMerge {
                    dismissAfterMerge = false
                    dismiss()
                }
            }) {
                MergeListsSheet(onMerged: { dismissAfterMerge = true })
                    .environmentObject(model)
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
                    locationPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    locationPendingDelete = nil
                }
            } message: { location in
                Text("Remove “\(location.name)” from Handy Field Guide? This only deletes your saved import. You can re-import the barchart later.")
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
            Text("EBIRD API")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            Button {
                importError = nil
                showingAPIImporter = true
            } label: {
                Label("Import via eBird API", systemImage: "network")
            }
            .buttonStyle(GuideChipStyle(selected: true))

            Text("Paste your free API key in Settings first (ebird.org/api/keygen).")
                .font(.caption)
                .foregroundStyle(GuideColor.muted)

            Text("BARCHART FILE")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)
                .padding(.top, 6)

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
        model.renameImportedLocation(location.id, to: renameText)
        locationPendingRename = nil
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
