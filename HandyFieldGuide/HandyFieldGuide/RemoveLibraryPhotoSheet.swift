import SwiftUI

/// One user-attached photo the Remove sheet can target.
struct RemovableLibraryPhoto: Identifiable, Hashable {
    var id: String
    var path: String
    var title: String
}

/// Payload for `.sheet(item:)` when choosing among library attaches.
struct RemoveLibraryPhotoRequest: Identifiable, Hashable {
    var id: String { photos.map(\.id).joined(separator: "|") }
    var photos: [RemovableLibraryPhoto]
    var initiallySelectedID: String?
}

/// Lets the user pick which library photo to delete when more than one is attached.
struct RemoveLibraryPhotoSheet: View {
    var photos: [RemovableLibraryPhoto]
    var initiallySelectedID: String?
    var onRemove: (String) -> Void
    var onCancel: () -> Void

    @State private var selectedID: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(photos.count == 1
                     ? "Remove this photo from the bird?"
                     : "Choose which photo to remove.")
                    .font(.body)
                    .foregroundStyle(GuideColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12),
                        ],
                        spacing: 12
                    ) {
                        ForEach(photos) { photo in
                            photoCell(photo)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button {
                    guard let selectedID else { return }
                    onRemove(selectedID)
                } label: {
                    Text(photos.count == 1 ? "Remove photo" : "Remove selected photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GuideChipStyle(selected: true))
                .disabled(selectedID == nil)
                .accessibilityHint("Deletes the highlighted library photo")
            }
            .padding(20)
            .guideBackground()
            .navigationTitle("Remove photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .onAppear {
                if let initiallySelectedID,
                   photos.contains(where: { $0.id == initiallySelectedID }) {
                    selectedID = initiallySelectedID
                } else {
                    selectedID = photos.first?.id
                }
            }
        }
        .presentationDetents(photos.count <= 2 ? [.medium] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func photoCell(_ photo: RemovableLibraryPhoto) -> some View {
        let isSelected = photo.id == selectedID
        Button {
            selectedID = photo.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    BundlePhoto(path: photo.path, alt: photo.title, fills: true, maxPixelSize: 360)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()

                    PhotoSourceBadge(source: .library, compact: true)
                        .padding(6)
                }

                Text(photo.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GuideColor.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(GuideColor.card)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(
                        isSelected ? GuideColor.green : GuideColor.line,
                        lineWidth: isSelected ? 3 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Selects this photo for removal")
    }
}
