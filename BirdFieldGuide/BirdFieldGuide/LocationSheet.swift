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
        LocationPreset(title: "Greater Melbourne", query: "Melbourne"),
        LocationPreset(title: "Bayside", query: "Bayside"),
        LocationPreset(title: "Inner Melbourne", query: "Inner Melbourne"),
        LocationPreset(title: "Dandenong Ranges", query: "Dandenong Ranges"),
        LocationPreset(title: "San José, Costa Rica", query: "San José"),
    ]

    init(current: String) {
        _draft = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Type a suburb, town, or region. Greater Melbourne is the default. San José has its own starter sample. Anywhere else stays on the closest list this guide actually has.")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Suburb, town, or region", text: $draft)
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
