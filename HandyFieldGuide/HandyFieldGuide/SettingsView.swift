import SwiftUI

/// Scarce / flagged list filters — kept off the main home UI.
struct SettingsView: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(
                        "Hide scarce / near-zero for \(model.selectedMonthName)",
                        isOn: Binding(
                            get: { model.hideNearZero },
                            set: { model.setHideNearZero($0) }
                        )
                    )
                    Toggle("Show flagged sp. / slash taxa", isOn: $model.showFlaggedTaxa)
                } footer: {
                    Text(
                        "Near-zero rows are below \(Int(EBirdBarchartParser.nearZeroThreshold * 1000) / 10)% mean frequency for the selected month. Flagged “sp.” and slash taxa stay off the main list unless you turn them on."
                    )
                }
            }
            .guideBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
