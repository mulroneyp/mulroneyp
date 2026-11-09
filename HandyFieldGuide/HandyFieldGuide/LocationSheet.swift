import SwiftUI
import UniformTypeIdentifiers

struct LocationSheet: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var showingImporter: Bool
    @State private var importError: String?
    @State private var renamingId: String?
    @State private var renameText = ""

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
                         : "Manage imported eBird areas, or type a curated place name. Use Add new on the home screen to import a barchart.")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    importSection

                    if !model.imports.locations.isEmpty {
                        importedSection
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
            .navigationTitle(startInImportMode ? "Add location" : "Locations")
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
        }
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
            Text("IMPORTED AREAS")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)
            ForEach(model.imports.locations) { location in
                VStack(alignment: .leading, spacing: 6) {
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

                    if renamingId == location.id {
                        HStack {
                            TextField("Rename", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                let previous = location.name
                                model.imports.rename(location.id, to: renameText)
                                if let updated = model.imports.locations.first(where: { $0.id == location.id }) {
                                    if model.locationQuery == previous {
                                        model.locationQuery = updated.name
                                    }
                                    draft = updated.name
                                }
                                renamingId = nil
                            }
                            .buttonStyle(GuideChipStyle(selected: true))
                        }
                    } else {
                        Button("Rename") {
                            renamingId = location.id
                            renameText = location.name
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GuideColor.green)
                    }
                }
            }
        }
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
