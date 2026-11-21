import SwiftUI

struct FieldDataProgressSheet: View {
    @ObservedObject var fetcher: ImportFieldDataFetcher
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(titleText)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(GuideColor.green)

                Text(bodyText)
                    .font(.body)
                    .foregroundStyle(GuideColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                progressBlock

                if fetcher.isActive, !fetcher.currentName.isEmpty {
                    Text("Now: \(fetcher.currentName)")
                        .font(.subheadline)
                        .foregroundStyle(GuideColor.muted)
                        .lineLimit(2)
                }

                Text(
                    ImportFieldDataFetcher.formatETA(
                        fetcher.isActive
                            ? fetcher.estimatedSecondsRemaining
                            : (fetcher.phase == .finished ? 0 : nil)
                    )
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GuideColor.green)

                if !fetcher.statusMessage.isEmpty, fetcher.phase != .running || fetcher.completed == 0 {
                    Text(fetcher.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(GuideColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if fetcher.isActive {
                    Button(role: .cancel) {
                        fetcher.cancel()
                    } label: {
                        Text("Cancel remaining lookups")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideChipStyle(selected: false))
                } else {
                    Button {
                        fetcher.dismissFinished()
                        dismiss()
                    } label: {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideChipStyle(selected: true))
                }
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .guideBackground()
            .navigationTitle("Descriptions & sizes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if fetcher.isActive {
                        Button("Cancel") { fetcher.cancel() }
                    } else {
                        Button("Close") {
                            fetcher.dismissFinished()
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(fetcher.isActive)
        }
        .presentationDetents([.medium, .large])
    }

    private var titleText: String {
        switch fetcher.phase {
        case .running: return "Filling blanks"
        case .cancelled: return "Update stopped"
        case .finished: return "Update finished"
        case .idle: return "Descriptions & sizes"
        }
    }

    private var bodyText: String {
        switch fetcher.phase {
        case .running:
            return "Looking up short appearance/ID lines and published lengths for species on this birdlist that still show blank description or size. Existing text is left alone."
        case .cancelled:
            return "Anything already saved stays cached on this device and is reused at other locations."
        case .finished:
            return "Filled notes are cached on this device and work offline. Curated guide text was not changed."
        case .idle:
            return ""
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fetcher.fractionComplete)
                .tint(GuideColor.green)
            HStack {
                Text(countLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GuideColor.ink)
                Spacer()
                Text(percentLabel)
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Description and size update progress")
        .accessibilityValue("\(fetcher.completed) of \(fetcher.total), \(percentLabel)")
    }

    private var countLabel: String {
        if fetcher.total == 0 {
            return "Nothing to update"
        }
        return "\(fetcher.completed) of \(fetcher.total) species"
    }

    private var percentLabel: String {
        guard fetcher.total > 0 else { return "100%" }
        return "\(Int((fetcher.fractionComplete * 100).rounded()))%"
    }
}
