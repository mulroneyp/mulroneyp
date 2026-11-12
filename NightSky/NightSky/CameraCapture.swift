import AVFoundation
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
            return "No camera is available. Night Sky needs a physical iPhone. The Simulator has no camera and cannot capture frames."
        case .noFormat:
            return "This camera has no format that supports a manual exposure."
        case .noImage:
            return "A frame came back empty. The series was stopped."
        case .configurationFailed(let detail):
            return "The camera could not be configured. \(detail)"
        }
    }
}

/// Rear-camera stills. The shutter speed is `activeFormat.maxExposureDuration`
/// (clamped to the frame duration that format allows). It is never a fixed constant.
final class CameraCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "nightsky.camera")
    private let stateLock = NSLock()
    private var device: AVCaptureDevice?
    private var photoContinuation: CheckedContinuation<Data, Error>?

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

    /// Selects the longest-exposure format and starts the session. Does not take a photo.
    func startSession() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try self.configureAndStart())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Locks focus near infinity and applies the active format's maximum exposure.
    func lockLongestExposure() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.applyLongestExposure(completion: continuation.resume(with:))
            }
        }
    }

    func captureFrame(maxEdge: Int) async throws -> FrameBuffer {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.stateLock.lock()
                if self.photoContinuation != nil {
                    self.stateLock.unlock()
                    continuation.resume(throwing: CameraError.configurationFailed("A capture is already in progress."))
                    return
                }
                self.photoContinuation = continuation
                self.stateLock.unlock()
                self.photoOutput.capturePhoto(with: self.makePhotoSettings(), delegate: self)
                self.sessionQueue.asyncAfter(deadline: .now() + 30) {
                    self.finishPhoto(.failure(CameraError.configurationFailed("The camera did not return a frame.")))
                }
            }
        }
        return try ImageEncoding.frameBuffer(data: data, maxEdge: maxEdge)
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.finishPhoto(.failure(CancellationError()))
                self.session.beginConfiguration()
                for input in self.session.inputs {
                    self.session.removeInput(input)
                }
                if self.session.outputs.contains(where: { $0 === self.photoOutput }) {
                    self.session.removeOutput(self.photoOutput)
                }
                self.session.commitConfiguration()
                self.device = nil
                continuation.resume()
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finishPhoto(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            finishPhoto(.failure(CameraError.noImage))
            return
        }
        finishPhoto(.success(data))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            finishPhoto(.failure(error))
        }
    }

    private func finishPhoto(_ result: Result<Data, Error>) {
        stateLock.lock()
        let continuation = photoContinuation
        photoContinuation = nil
        stateLock.unlock()
        continuation?.resume(with: result)
    }

    private func configureAndStart() throws -> TimeInterval {
        guard let device = rearCamera() else { throw CameraError.noCamera }
        self.device = device
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        var didCommit = false
        func commit() {
            if !didCommit {
                session.commitConfiguration()
                didCommit = true
            }
        }

        guard session.canAddInput(input) else {
            commit()
            throw CameraError.configurationFailed("Could not use the rear camera.")
        }
        session.addInput(input)

        let format: AVCaptureDevice.Format
        do {
            try device.lockForConfiguration()
        } catch {
            commit()
            throw CameraError.configurationFailed(error.localizedDescription)
        }
        do {
            format = try bestFormat(on: device)
            device.activeFormat = format
            if let slowest = format.videoSupportedFrameRateRanges.max(by: {
                CMTimeCompare($0.maxFrameDuration, $1.maxFrameDuration) < 0
            }) {
                // Raise the maximum frame duration before the minimum. The other
                // order traps when the new minimum is longer than the old maximum.
                device.activeVideoMaxFrameDuration = slowest.maxFrameDuration
                device.activeVideoMinFrameDuration = slowest.maxFrameDuration
            }
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

        guard session.canAddOutput(photoOutput) else {
            commit()
            throw CameraError.configurationFailed("Could not use the photo output.")
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .speed
        if let dimensions = choosePhotoDimensions(format.supportedMaxPhotoDimensions) {
            photoOutput.maxPhotoDimensions = dimensions
        }

        commit()
        if !session.isRunning {
            session.startRunning()
        }

        let duration = longestUsableExposure(on: device)
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
            throw CameraError.noFormat
        }
        return duration.seconds
    }

    private func applyLongestExposure(completion: @escaping (Result<TimeInterval, Error>) -> Void) {
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
        guard device.isExposureModeSupported(.custom) else {
            device.unlockForConfiguration()
            completion(.failure(CameraError.configurationFailed("Custom exposure is not supported.")))
            return
        }

        if device.isLockingFocusWithCustomLensPositionSupported {
            // 1.0 is the far end of the lens range (infinity), which is what stars need.
            device.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil)
        } else if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: clampedGains(device), completionHandler: nil)
        }

        let duration = longestUsableExposure(on: device)
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
            device.unlockForConfiguration()
            completion(.failure(CameraError.noFormat))
            return
        }
        let iso = chosenISO(on: device)

        let gate = NSLock()
        var finished = false
        func complete(_ result: Result<TimeInterval, Error>) {
            gate.lock()
            defer { gate.unlock() }
            if finished { return }
            finished = true
            completion(result)
        }

        sessionQueue.asyncAfter(deadline: .now() + 6) {
            complete(.success(duration.seconds))
        }
        device.setExposureModeCustom(duration: duration, iso: iso) { [weak self] _ in
            device.unlockForConfiguration()
            guard let self else {
                complete(.success(duration.seconds))
                return
            }
            self.waitUntilExposureSettles(device: device, attempts: 40) {
                complete(.success(duration.seconds))
            }
        }
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

    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0 && dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }
        settings.photoQualityPrioritization = .speed
        return settings
    }

    /// Longest exposure the active format can deliver. Frame duration can cap the format maximum.
    private func longestUsableExposure(on device: AVCaptureDevice) -> CMTime {
        var duration = device.activeFormat.maxExposureDuration
        let frameCap = device.activeVideoMaxFrameDuration
        if frameCap.isValid && frameCap.seconds > 0 && CMTimeCompare(duration, frameCap) > 0 {
            duration = frameCap
        }
        let minimum = device.activeFormat.minExposureDuration
        if minimum.isValid && CMTimeCompare(duration, minimum) < 0 {
            duration = minimum
        }
        return duration
    }

    private func usableExposure(of format: AVCaptureDevice.Format) -> CMTime {
        var duration = format.maxExposureDuration
        if let slowest = format.videoSupportedFrameRateRanges.max(by: {
            CMTimeCompare($0.maxFrameDuration, $1.maxFrameDuration) < 0
        }), CMTimeCompare(duration, slowest.maxFrameDuration) > 0 {
            duration = slowest.maxFrameDuration
        }
        return duration
    }

    private func bestFormat(on device: AVCaptureDevice) throws -> AVCaptureDevice.Format {
        let usable = device.formats.filter { format in
            format.maxExposureDuration.isValid && format.maxExposureDuration.seconds > 0
        }
        let withStills = usable.filter { !$0.supportedMaxPhotoDimensions.isEmpty }
        let pool = withStills.isEmpty ? usable : withStills
        guard let best = pool.max(by: { lhs, rhs in
            let order = CMTimeCompare(usableExposure(of: lhs), usableExposure(of: rhs))
            if order != 0 { return order < 0 }
            return stillPixels(lhs) < stillPixels(rhs)
        }) else {
            throw CameraError.noFormat
        }
        return best
    }

    private func stillPixels(_ format: AVCaptureDevice.Format) -> Int {
        format.supportedMaxPhotoDimensions.reduce(0) { partial, dims in
            max(partial, Int(dims.width) * Int(dims.height))
        }
    }

    private func choosePhotoDimensions(_ supported: [CMVideoDimensions]) -> CMVideoDimensions? {
        let valid = supported.filter { $0.width > 0 && $0.height > 0 }
        guard !valid.isEmpty else { return nil }
        let target = 2000
        let adequate = valid.filter { max(Int($0.width), Int($0.height)) >= 1280 }
        let pool = adequate.isEmpty ? valid : adequate
        return pool.min { lhs, rhs in
            abs(max(Int(lhs.width), Int(lhs.height)) - target) < abs(max(Int(rhs.width), Int(rhs.height)) - target)
        }
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
