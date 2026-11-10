import SwiftUI

struct PhotoFetchProgressSheet: View {
    @ObservedObject var fetcher: ImportPhotoFetcher
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

                Text(ImportPhotoFetcher.formatETA(fetcher.isActive ? fetcher.estimatedSecondsRemaining : (fetcher.phase == .finished ? 0 : nil)))
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
                        Text("Cancel remaining downloads")
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
            .navigationTitle("Photos")
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
        case .running: return "Fetching photos"
        case .cancelled: return "Photo fetch stopped"
        case .finished: return "Photos ready"
        case .idle: return "Photos"
        }
    }

    private var bodyText: String {
        switch fetcher.phase {
        case .running:
            return "Looking up Wikimedia Commons images for species in this import that do not already have a local photo. Attribution is saved for Photo Attr."
        case .cancelled:
            return "The import itself is unchanged. Any photos already downloaded stay cached for reuse at other locations."
        case .finished:
            return "Open-licence photos are cached on this device and work offline. Bundled guide photos were left alone."
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
        .accessibilityLabel("Photo download progress")
        .accessibilityValue("\(fetcher.completed) of \(fetcher.total), \(percentLabel)")
    }

    private var countLabel: String {
        if fetcher.total == 0 {
            return "Nothing to fetch"
        }
        return "\(fetcher.completed) of \(fetcher.total) species"
    }

    private var percentLabel: String {
        guard fetcher.total > 0 else { return "100%" }
        return "\(Int((fetcher.fractionComplete * 100).rounded()))%"
    }
}
