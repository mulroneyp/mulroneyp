import AVFoundation
import CoreVideo
import Foundation
import NightSkyStack

enum CameraError: LocalizedError {
    case permissionDenied
    case noCamera
    case noFormat
    case noImage
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera access is off. Enable it in Settings to capture the sky."
        case .noCamera:
            return "No camera is available. MyNightSky needs a physical iPhone. The Simulator has no camera and cannot capture frames."
        case .noFormat:
            return "This camera has no format that supports a manual exposure."
        case .noImage:
            return "A frame came back empty. The series was stopped."
        case .configurationFailed(let detail):
            return "The camera could not be configured. \(detail)"
        }
    }
}

/// Rear-camera frames at the active format's longest exposure.
///
/// Stills go through `AVCaptureVideoDataOutput`, not `AVCapturePhotoOutput`.
/// The photo output failed on device with AVFoundationErrorDomain -11800
/// ("The operation could not be completed") after the shutter fired.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "nightsky.camera")
    private let videoQueue = DispatchQueue(label: "nightsky.frames")
    private let stateLock = NSLock()
    private var device: AVCaptureDevice?
    private var exposureReady = false
    private var buffersToDrop = 0
    private var exposureSeconds: TimeInterval = 1
    private var pendingFrame: PendingFrame?

    private struct PendingFrame {
        let id: Int
        let maxEdge: Int
        let continuation: CheckedContinuation<FrameBuffer, Error>
    }

    private var nextFrameID = 0

    override init() {
        super.init()
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
    }

    func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CameraError.permissionDenied }
        default:
            throw CameraError.permissionDenied
        }
    }

    func ensureRearCamera() throws {
        guard rearCamera() != nil else { throw CameraError.noCamera }
    }

    /// Opens the rear camera at a normal frame rate and locks focus at infinity
    /// when the lens supports it. Call this before the countdown. It does not
    /// start the long exposure.
    func prepareSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureAndStart()
                    self.lockFocusAtInfinity { result in
                        continuation.resume(with: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Switches the running session to the format's longest exposure.
    /// The first saved frame is taken after this returns.
    func beginLongExposure() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.applyLongExposure(completion: continuation.resume(with:))
            }
        }
    }

    func captureFrame(maxEdge: Int) async throws -> FrameBuffer {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.stateLock.lock()
                if self.pendingFrame != nil {
                    self.stateLock.unlock()
                    continuation.resume(throwing: CameraError.configurationFailed("A capture is already in progress."))
                    return
                }
                self.nextFrameID += 1
                let frameID = self.nextFrameID
                self.pendingFrame = PendingFrame(
                    id: frameID,
                    maxEdge: maxEdge,
                    continuation: continuation
                )
                let timeout = self.exposureSeconds + 8
                self.stateLock.unlock()
                self.sessionQueue.asyncAfter(deadline: .now() + timeout) {
                    self.failPending(
                        id: frameID,
                        CameraError.configurationFailed("The camera did not return a frame.")
                    )
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.stateLock.lock()
                self.exposureReady = false
                let pending = self.pendingFrame
                self.pendingFrame = nil
                self.stateLock.unlock()
                pending?.continuation.resume(throwing: CancellationError())
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.session.beginConfiguration()
                for input in self.session.inputs {
                    self.session.removeInput(input)
                }
                if self.session.outputs.contains(where: { $0 === self.videoOutput }) {
                    self.session.removeOutput(self.videoOutput)
                }
                self.session.commitConfiguration()
                self.device = nil
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        stateLock.lock()
        guard exposureReady else {
            stateLock.unlock()
            return
        }
        if buffersToDrop > 0 {
            buffersToDrop -= 1
            stateLock.unlock()
            return
        }
        guard let pending = pendingFrame else {
            stateLock.unlock()
            return
        }
        pendingFrame = nil
        stateLock.unlock()

        let rotation = Int(connection.videoRotationAngle.rounded())
        let mirrored = connection.isVideoMirrored
        do {
            let frame = try ImageEncoding.frameBuffer(
                from: pixelBuffer,
                maxEdge: pending.maxEdge,
                rotationDegrees: rotation,
                mirrored: mirrored
            )
            pending.continuation.resume(returning: frame)
        } catch {
            pending.continuation.resume(throwing: error)
        }
    }

    private func failPending(id: Int, _ error: Error) {
        stateLock.lock()
        guard let pending = pendingFrame, pending.id == id else {
            stateLock.unlock()
            return
        }
        pendingFrame = nil
        stateLock.unlock()
        pending.continuation.resume(throwing: error)
    }

    private func configureAndStart() throws {
        stateLock.lock()
        exposureReady = false
        buffersToDrop = 0
        pendingFrame = nil
        stateLock.unlock()

        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        var didCommit = false
        func commit() {
            if !didCommit {
                session.commitConfiguration()
                didCommit = true
            }
        }

        for input in session.inputs {
            session.removeInput(input)
        }
        if session.outputs.contains(where: { $0 === videoOutput }) {
            session.removeOutput(videoOutput)
        }

        guard let device = rearCamera() else {
            commit()
            throw CameraError.noCamera
        }
        self.device = device
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            commit()
            throw CameraError.configurationFailed("Could not use the rear camera.")
        }
        session.addInput(input)

        do {
            try device.lockForConfiguration()
        } catch {
            commit()
            throw CameraError.configurationFailed(error.localizedDescription)
        }
        do {
            let format = try bestFormat(on: device)
            device.activeFormat = format
            setLockedFrameDuration(warmupDuration(for: format), on: device)
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = false
            }
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = false
            }
            let minZoom = device.minAvailableVideoZoomFactor
            let maxZoom = device.maxAvailableVideoZoomFactor
            device.videoZoomFactor = min(max(1, minZoom), maxZoom)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
            commit()
            throw error
        }

        guard session.canAddOutput(videoOutput) else {
            commit()
            throw CameraError.configurationFailed("Could not use the camera output.")
        }
        session.addOutput(videoOutput)
        if !videoOutput.availableVideoPixelFormatTypes.isEmpty
            && !videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
            commit()
            throw CameraError.configurationFailed("This camera cannot deliver frames this app can read.")
        }
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        commit()
        if !session.isRunning {
            session.startRunning()
        }
        guard session.isRunning else {
            throw CameraError.configurationFailed("The camera did not start.")
        }
    }

    /// Raise the maximum before the minimum when the new duration is longer,
    /// and lower the minimum first when it is shorter. The other order throws.
    private func setLockedFrameDuration(_ duration: CMTime, on device: AVCaptureDevice) {
        let currentMin = device.activeVideoMinFrameDuration
        let currentMax = device.activeVideoMaxFrameDuration
        if CMTimeCompare(duration, currentMax) > 0 {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else if currentMin.isValid && CMTimeCompare(duration, currentMin) < 0 {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } else {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        }
    }

    private func lockFocusAtInfinity(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let device else {
            completion(.failure(CameraError.noCamera))
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            completion(.failure(CameraError.configurationFailed(error.localizedDescription)))
            return
        }
        guard device.isLockingFocusWithCustomLensPositionSupported else {
            device.unlockForConfiguration()
            completion(.success(()))
            return
        }

        let gate = NSLock()
        var finished = false
        let finish: () -> Void = {
            gate.lock()
            let go = !finished
            finished = true
            gate.unlock()
            guard go else { return }
            device.unlockForConfiguration()
            completion(.success(()))
        }
        device.setFocusModeLocked(lensPosition: 1.0) { _ in
            self.sessionQueue.async { finish() }
        }
        sessionQueue.asyncAfter(deadline: .now() + 3) {
            finish()
        }
    }

    private func applyLongExposure(completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        guard let device else {
            completion(.failure(CameraError.noCamera))
            return
        }
        stateLock.lock()
        exposureReady = false
        buffersToDrop = 0
        stateLock.unlock()

        do {
            try device.lockForConfiguration()
        } catch {
            completion(.failure(CameraError.configurationFailed(error.localizedDescription)))
            return
        }
        guard device.isExposureModeSupported(.custom) else {
            device.unlockForConfiguration()
            completion(.failure(CameraError.configurationFailed("Custom exposure is not supported.")))
            return
        }

        let duration = clampedDuration(longestExposure(for: device.activeFormat), on: device.activeFormat)
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
            device.unlockForConfiguration()
            completion(.failure(CameraError.noFormat))
            return
        }
        setLockedFrameDuration(duration, on: device)

        let continueExposure = { [weak self] in
            guard let self else {
                device.unlockForConfiguration()
                completion(.failure(CameraError.noCamera))
                return
            }
            self.applyExposure(on: device, duration: duration, completion: completion)
        }

        let needsFocus = device.isLockingFocusWithCustomLensPositionSupported
            && (device.focusMode != .locked || abs(device.lensPosition - 1) > 0.02)
        guard needsFocus else {
            continueExposure()
            return
        }

        let gate = NSLock()
        var started = false
        let start = { [weak self] in
            gate.lock()
            let go = !started
            started = true
            gate.unlock()
            guard go else { return }
            self?.sessionQueue.async { continueExposure() }
        }
        device.setFocusModeLocked(lensPosition: 1.0) { _ in
            start()
        }
        sessionQueue.asyncAfter(deadline: .now() + 3) {
            start()
        }
    }

    private func applyExposure(
        on device: AVCaptureDevice,
        duration: CMTime,
        completion: @escaping (Result<TimeInterval, Error>) -> Void
    ) {
        let gate = NSLock()
        var finished = false
        let finish: (Result<TimeInterval, Error>) -> Void = { result in
            gate.lock()
            let go = !finished
            finished = true
            gate.unlock()
            guard go else { return }
            device.unlockForConfiguration()
            if case .success(let seconds) = result {
                self.markExposureReady(seconds)
            }
            completion(result)
        }

        let startExposure = { [weak self] in
            gate.lock()
            let alreadyFinished = finished
            gate.unlock()
            // The timeout may already have unlocked the device. Do not touch it then.
            if alreadyFinished { return }
            guard let self else {
                finish(.failure(CameraError.noCamera))
                return
            }
            let iso = self.chosenISO(on: device)
            device.setExposureModeCustom(duration: duration, iso: iso) { _ in
                self.sessionQueue.async {
                    self.waitUntilExposureSettles(device: device, attempts: 40) {
                        finish(.success(duration.seconds))
                    }
                }
            }
        }

        let limit = max(8, duration.seconds + 4)
        sessionQueue.asyncAfter(deadline: .now() + limit) {
            finish(.failure(CameraError.configurationFailed("The camera did not apply the longest exposure.")))
        }

        if device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: clampedGains(device)) { _ in
                self.sessionQueue.async { startExposure() }
            }
        } else {
            startExposure()
        }
    }

    private func markExposureReady(_ seconds: TimeInterval) {
        stateLock.lock()
        exposureSeconds = seconds
        buffersToDrop = 1
        exposureReady = true
        stateLock.unlock()
    }

    private func waitUntilExposureSettles(
        device: AVCaptureDevice,
        attempts: Int,
        done: @escaping () -> Void
    ) {
        if !device.isAdjustingExposure || attempts <= 0 {
            done()
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilExposureSettles(device: device, attempts: attempts - 1, done: done)
        }
    }

    /// Longest exposure the format can deliver. Frame duration can cap the format maximum.
    private func longestExposure(for format: AVCaptureDevice.Format) -> CMTime {
        var duration = format.maxExposureDuration
        if let slowest = format.videoSupportedFrameRateRanges.max(by: {
            CMTimeCompare($0.maxFrameDuration, $1.maxFrameDuration) < 0
        }), CMTimeCompare(duration, slowest.maxFrameDuration) > 0 {
            duration = slowest.maxFrameDuration
        }
        return duration
    }

    private func clampedDuration(_ duration: CMTime, on format: AVCaptureDevice.Format) -> CMTime {
        guard let range = format.videoSupportedFrameRateRanges.first(where: {
            CMTimeCompare($0.minFrameDuration, duration) <= 0
                && CMTimeCompare(duration, $0.maxFrameDuration) <= 0
        }) ?? format.videoSupportedFrameRateRanges.max(by: {
            CMTimeCompare($0.maxFrameDuration, $1.maxFrameDuration) < 0
        }) else { return duration }
        var clamped = duration
        if CMTimeCompare(clamped, range.minFrameDuration) < 0 {
            clamped = range.minFrameDuration
        }
        if CMTimeCompare(clamped, range.maxFrameDuration) > 0 {
            clamped = range.maxFrameDuration
        }
        return clamped
    }

    private func warmupDuration(for format: AVCaptureDevice.Format) -> CMTime {
        let fps30 = CMTime(value: 1, timescale: 30)
        if format.videoSupportedFrameRateRanges.contains(where: {
            CMTimeCompare($0.minFrameDuration, fps30) <= 0 && CMTimeCompare(fps30, $0.maxFrameDuration) <= 0
        }) {
            return fps30
        }
        let fastest = format.videoSupportedFrameRateRanges.min {
            CMTimeCompare($0.minFrameDuration, $1.minFrameDuration) < 0
        }
        return fastest?.minFrameDuration ?? fps30
    }

    private func bestFormat(on device: AVCaptureDevice) throws -> AVCaptureDevice.Format {
        let usable = device.formats.filter { format in
            format.maxExposureDuration.isValid
                && format.maxExposureDuration.seconds > 0
                && !format.videoSupportedFrameRateRanges.isEmpty
        }
        guard let best = usable.max(by: { lhs, rhs in
            let order = CMTimeCompare(longestExposure(for: lhs), longestExposure(for: rhs))
            if order != 0 { return order < 0 }
            return videoPixels(lhs) < videoPixels(rhs)
        }) else {
            throw CameraError.noFormat
        }
        return best
    }

    private func videoPixels(_ format: AVCaptureDevice.Format) -> Int {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dims.width) * Int(dims.height)
    }

    private func chosenISO(on device: AVCaptureDevice) -> Float {
        let format = device.activeFormat
        return min(format.maxISO, max(format.minISO, 1600))
    }

    private func clampedGains(_ device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var gains = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        func clamp(_ value: Float) -> Float {
            guard value.isFinite else { return 1 }
            return min(max(value, 1), maxGain)
        }
        gains.redGain = clamp(gains.redGain)
        gains.greenGain = clamp(gains.greenGain)
        gains.blueGain = clamp(gains.blueGain)
        return gains
    }

    private func rearCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
}
