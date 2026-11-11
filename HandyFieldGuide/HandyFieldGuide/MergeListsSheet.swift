import SwiftUI

/// Multi-select saved imports and merge them into a new named list.
struct MergeListsSheet: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss

    /// Optional hook so a presenting Manage sheet can dismiss after a successful merge
    /// and leave room for the on-import photo fetch sheet.
    var onMerged: (() -> Void)? = nil

    @State private var selectedIds: Set<String> = []
    @State private var mergedName = ""
    @State private var mergeError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Select two or more saved imports from nearby hotspots. The new list unions every species and, for matching week and month columns, keeps the highest rate — never a sum. Source lists stay in the Location menu until you delete them.")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    nameSection
                    sourcesSection

                    if let mergeError {
                        Text(mergeError)
                            .font(.footnote)
                            .foregroundStyle(GuideColor.rust)
                    }

                    Button {
                        performMerge()
                    } label: {
                        Label("Merge into new list", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(GuideChipStyle(selected: canMerge))
                    .disabled(!canMerge)
                    .accessibilityHint("Creates a new saved list and keeps the selected sources")
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .guideBackground()
            .navigationTitle("Merge lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var canMerge: Bool {
        selectedIds.count >= 2
            && !mergedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW LIST NAME")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            TextField("e.g. San José area", text: $mergedName)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVED IMPORTS")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(GuideColor.muted)

            if model.imports.locations.count < 2 {
                Text("Import at least two eBird barcharts before merging.")
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
            } else {
                ForEach(model.imports.locations) { location in
                    Button {
                        toggle(location.id)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selectedIds.contains(location.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedIds.contains(location.id) ? GuideColor.green : GuideColor.muted)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(GuideColor.ink)
                                Text("\(location.species.count) taxa · \(location.placeTitle)")
                                    .font(.caption)
                                    .foregroundStyle(GuideColor.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(GuideColor.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(
                                    selectedIds.contains(location.id)
                                        ? GuideColor.green.opacity(0.7)
                                        : GuideColor.green.opacity(0.35),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedIds.contains(location.id) ? .isSelected : [])
                    .accessibilityLabel(location.name)
                    .accessibilityHint("Select to include in the merge")
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
        mergeError = nil
    }

    private func performMerge() {
        mergeError = nil
        do {
            _ = try model.mergeImportedLocations(
                ids: Array(selectedIds),
                displayName: mergedName
            )
            onMerged?()
            dismiss()
        } catch {
            mergeError = error.localizedDescription
        }
    }
}
