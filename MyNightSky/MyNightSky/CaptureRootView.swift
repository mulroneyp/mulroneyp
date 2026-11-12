import NightSkyStack
import SwiftUI

struct CaptureRootView: View {
    @ObservedObject var model: NightCaptureModel

    private var hidesChrome: Bool {
        switch model.timeline.phase {
        case .countdown, .capturing, .stacking:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            NightColor.background.ignoresSafeArea()
            switch model.timeline.phase {
            case .ready:
                ReadyView(model: model)
            case .countdown(let seconds):
                CountdownView(model: model, seconds: seconds)
            case .capturing(let done, let total):
                CapturingView(model: model, done: done, total: total)
            case .stacking(let total):
                StackingView(frameCount: total)
            case .preview:
                PreviewView(model: model)
            case .failed(let message):
                FailedView(model: model, message: message)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(hidesChrome ? .hidden : .automatic)
    }
}

private struct ReadyView: View {
    @ObservedObject var model: NightCaptureModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("MyNightSky")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(NightColor.text)
                SetupInstruction()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Frames")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(NightColor.muted)
                    HStack(spacing: 16) {
                        countButton(title: "−", delta: -1)
                        Text("\(model.frameCount)")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .foregroundStyle(NightColor.text)
                            .frame(minWidth: 72)
                            .accessibilityLabel("\(model.frameCount) frames")
                        countButton(title: "+", delta: 1)
                    }
                    Text("Default is 10. Each frame uses the longest exposure this camera allows.")
                        .font(.body)
                        .foregroundStyle(NightColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NightButton(title: model.isStarting ? "Waiting for camera…" : "Start") {
                    model.start()
                }
                .disabled(model.isStarting)
                .opacity(model.isStarting ? 0.55 : 1)
            }
            .padding(24)
        }
    }

    private func countButton(title: String, delta: Int) -> some View {
        let atLimit = delta < 0
            ? model.frameCount <= SeriesTimeline.minimumFrameCount
            : model.frameCount >= SeriesTimeline.maximumFrameCount
        return Button {
            model.changeFrameCount(by: delta)
        } label: {
            Text(title)
                .font(.largeTitle.weight(.medium))
                .frame(width: 64, height: 64)
                .foregroundStyle(NightColor.text)
                .overlay(Circle().stroke(NightColor.text, lineWidth: 1.5))
        }
        .buttonStyle(NightPressStyle())
        .disabled(atLimit)
        .opacity(atLimit ? 0.35 : 1)
        .accessibilityLabel(delta < 0 ? "Fewer frames" : "More frames")
    }
}

private struct CountdownView: View {
    @ObservedObject var model: NightCaptureModel
    var seconds: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SetupInstruction()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Starts in")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(NightColor.muted)
                    Text("\(seconds)")
                        .font(.system(size: 108, weight: .semibold, design: .rounded))
                        .foregroundStyle(NightColor.text)
                        .minimumScaleFactor(0.5)
                        .accessibilityLabel("Starts in \(seconds) seconds")
                    Text(NightCopy.countdownHint)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(NightColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NightButton(title: "Cancel") {
                    model.cancel()
                }
            }
            .padding(24)
        }
    }
}

private struct CapturingView: View {
    @ObservedObject var model: NightCaptureModel
    var done: Int
    var total: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Capturing")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(NightColor.text)
                Text(nightClock(model.timeline.elapsed(at: model.now)))
                    .font(.system(size: 88, weight: .semibold, design: .rounded))
                    .foregroundStyle(NightColor.text)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel("Elapsed \(nightClock(model.timeline.elapsed(at: model.now)))")
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.timeline.framesRemaining) \(model.timeline.framesRemaining == 1 ? "frame" : "frames") left")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(NightColor.text)
                    Text("\(done) of \(total) captured")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(NightColor.muted)
                    if let seconds = model.timeline.exposureDuration {
                        Text("\(nightSeconds(seconds)) exposure, from this camera")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(NightColor.muted)
                    }
                    statusLine
                        .font(.title3.weight(.medium))
                        .foregroundStyle(NightColor.muted)
                }
                Text(NightCopy.capturingHint)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(NightColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                NightButton(title: "Cancel") {
                    model.cancel()
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.timeline.exposureDuration == nil {
            Text("Starting camera")
        } else if done == 0 {
            Text("Setting the longest exposure")
        } else if let remaining = model.timeline.estimatedTimeRemaining {
            Text("About \(nightSeconds(remaining)) left")
        } else {
            Text("Hold still")
        }
    }
}

private struct StackingView: View {
    var frameCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(NightCopy.safeToPickUp)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(NightColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Aligning and stacking \(frameCount) frames")
                .font(.title3.weight(.medium))
                .foregroundStyle(NightColor.muted)
            ProgressView()
                .controlSize(.large)
                .tint(NightColor.text)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

private struct PreviewView: View {
    @ObservedObject var model: NightCaptureModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Stacked photo")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(NightColor.text)
                if let preview = model.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(NightColor.background)
                }
                caption
                if case .failed(let message) = model.saveState {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(NightColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NightButton(title: saveTitle) {
                    model.save()
                }
                .disabled(model.saveState == .saving || model.saveState == .saved)
                .opacity(model.saveState == .saving || model.saveState == .saved ? 0.55 : 1)
                if model.failure == .photoPermission {
                    NightButton(title: "Open Settings") {
                        model.openSettings()
                    }
                }
                NightButton(title: "Start over") {
                    model.startOver()
                }
            }
            .padding(24)
        }
    }

    private var saveTitle: String {
        switch model.saveState {
        case .idle, .failed:
            return "Save to Photos"
        case .saving:
            return "Saving…"
        case .saved:
            return "Saved to Photos"
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let seconds = model.timeline.exposureDuration {
            Text("\(model.timeline.frameCount) frames · \(nightSeconds(seconds)) each")
                .font(.title3.weight(.medium))
                .foregroundStyle(NightColor.muted)
        } else {
            Text("\(model.timeline.frameCount) frames")
                .font(.title3.weight(.medium))
                .foregroundStyle(NightColor.muted)
        }
    }
}

private struct FailedView: View {
    @ObservedObject var model: NightCaptureModel
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Could not finish")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(NightColor.text)
            Text(message)
                .font(.title3.weight(.medium))
                .foregroundStyle(NightColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.failure == .cameraPermission || model.failure == .photoPermission {
                NightButton(title: "Open Settings") {
                    model.openSettings()
                }
            }
            NightButton(title: "Back") {
                model.startOver()
            }
        }
        .padding(24)
    }
}
