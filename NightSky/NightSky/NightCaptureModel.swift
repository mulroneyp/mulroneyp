import NightSkyStack
import SwiftUI
import UIKit

enum StackTuning {
    static let workingMaxEdge = 1280
    static let alignment = AlignmentOptions(searchRadius: 48, coarseMaxEdge: 160, fineStride: 2)
}

enum CaptureFailure: Equatable {
    case cameraPermission
    case photoPermission
    case noCamera
    case message(String)
}

enum SaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

@MainActor
final class NightCaptureModel: ObservableObject {
    @Published var frameCount = SeriesTimeline.defaultFrameCount
    @Published private(set) var timeline = SeriesTimeline(frameCount: SeriesTimeline.defaultFrameCount)
    @Published private(set) var now = Date()
    @Published private(set) var preview: UIImage?
    @Published private(set) var isStarting = false
    @Published private(set) var failure: CaptureFailure?
    @Published private(set) var saveState: SaveState = .idle

    private let camera = CameraCapture()
    private var work: Task<Void, Never>?
    private var clock: Task<Void, Never>?

    func changeFrameCount(by delta: Int) {
        guard timeline.phase == .ready else { return }
        let next = frameCount + delta
        frameCount = min(SeriesTimeline.maximumFrameCount, max(SeriesTimeline.minimumFrameCount, next))
    }

    func start() {
        guard timeline.phase == .ready, work == nil else { return }
        work = Task { await self.runSeries() }
    }

    func cancel() {
        work?.cancel()
        Task { await self.camera.stop() }
    }

    func startOver() {
        switch timeline.phase {
        case .preview, .failed:
            break
        default:
            return
        }
        preview = nil
        saveState = .idle
        failure = nil
        timeline.reset()
    }

    func save() {
        guard let preview, saveState != .saving else { return }
        saveState = .saving
        Task {
            do {
                try await PhotoLibrarySaver.save(preview)
                saveState = .saved
            } catch let error as PhotoSaveError {
                saveState = .failed(error.localizedDescription)
                if case .permissionDenied = error {
                    failure = .photoPermission
                }
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func runSeries() async {
        isStarting = true
        failure = nil
        saveState = .idle
        preview = nil
        UIApplication.shared.isIdleTimerDisabled = true
        startClock()
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isStarting = false
            work = nil
            stopClock()
        }

        do {
            try await camera.authorize()
            try Task.checkCancellation()
            try camera.ensureRearCamera()

            timeline = SeriesTimeline(frameCount: frameCount)
            timeline.startCountdown()
            isStarting = false

            while case .countdown = timeline.phase {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                _ = timeline.tickCountdown()
            }

            // The shutter series stays closed until every countdown second has elapsed.
            guard timeline.exposureMayBegin else { return }

            timeline.noteCaptureStarted(at: Date())
            let reported = try await camera.startSession()
            timeline.exposureDuration = reported
            let locked = try await camera.lockLongestExposure()
            timeline.exposureDuration = locked

            var captured: [FrameBuffer] = []
            captured.reserveCapacity(timeline.frameCount)
            while timeline.framesRemaining > 0 {
                try Task.checkCancellation()
                let frame = try await camera.captureFrame(maxEdge: StackTuning.workingMaxEdge)
                captured.append(frame)
                timeline.noteFrameCaptured()
            }

            await camera.stop()
            guard timeline.beginStacking() else { return }

            let frames = captured
            let options = StackTuning.alignment
            let stacked = try await Task.detached(priority: .userInitiated) {
                try stackAligned(frames, options: options, mode: .median)
            }.value
            guard let image = ImageEncoding.image(from: stacked) else {
                throw CameraError.noImage
            }
            preview = image
            timeline.finishPreview()
        } catch is CancellationError {
            await camera.stop()
            preview = nil
            timeline.reset()
        } catch let error as CameraError {
            await camera.stop()
            preview = nil
            switch error {
            case .permissionDenied:
                failure = .cameraPermission
            case .noCamera:
                failure = .noCamera
            default:
                failure = .message(error.localizedDescription)
            }
            timeline.fail(error.localizedDescription)
        } catch {
            await camera.stop()
            preview = nil
            failure = .message(error.localizedDescription)
            timeline.fail(error.localizedDescription)
        }
    }

    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                await MainActor.run { self?.now = Date() }
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }
}
