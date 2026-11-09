import SwiftUI

struct LocationPreset: Identifiable {
    var id: String { query }
    var title: String
    var query: String
}

struct LocationSheet: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    private let presets = [
        LocationPreset(title: "Children's Eternal Rainforest", query: "Monteverde"),
        LocationPreset(title: "San Gerardo", query: "San Gerardo"),
        LocationPreset(title: "Bajo del Tigre", query: "Bajo del Tigre"),
        LocationPreset(title: "Greater Melbourne", query: "Melbourne"),
        LocationPreset(title: "Bayside", query: "Bayside"),
        LocationPreset(title: "Dandenong Ranges", query: "Dandenong Ranges"),
    ]

    init(current: String) {
        _draft = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Handy Field Guide. Type a place. The main list is the Children's Eternal Rainforest checklist for Monteverde. Greater Melbourne is a second list. Anywhere else shows the closest list this guide actually has, and says when that list is not for the place you typed.")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Place", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(apply)

                    Button("Use this place", action: apply)
                        .buttonStyle(GuideChipStyle(selected: true))

                    Text("PRESETS")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(GuideColor.muted)

                    FlowPresets(presets: presets, selected: draft) { preset in
                        draft = preset.query
                        apply()
                    }
                }
                .padding(20)
            }
            .guideBackground()
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func apply() {
        model.locationQuery = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}

private struct FlowPresets: View {
    var presets: [LocationPreset]
    var selected: String
    var onSelect: (LocationPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(presets) { preset in
                Button(preset.title) { onSelect(preset) }
                    .buttonStyle(GuideChipStyle(selected: LocationResolver.normalize(selected) == LocationResolver.normalize(preset.query) || LocationResolver.normalize(selected) == LocationResolver.normalize(preset.title)))
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
