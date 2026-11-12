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

/// Rear-camera stills. The shutter speed is `activeFormat.maxExposureDuration`
/// (clamped to the frame duration that format allows). It is never a fixed constant.
final class CameraCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "nightsky.camera")
    private let stateLock = NSLock()
    private var device: AVCaptureDevice?
    private var photoContinuation: CheckedContinuation<Data, Error>?
    /// Filled by didFinishProcessingPhoto. Delivered only from didFinishCaptureFor,
    /// so the next capturePhoto cannot start while this one is still in flight.
    private var processedPhoto: Result<Data, Error>?

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

    /// Locks the lens at 1.0 when the camera supports it, then applies the
    /// active format's maximum exposure. The lock is left in place for the series.
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
                self.processedPhoto = nil
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
            storeProcessed(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            storeProcessed(.failure(CameraError.noImage))
            return
        }
        storeProcessed(.success(data))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        // Starting another capturePhoto before this callback is what makes the
        // next frame fail with "The operation could not be completed."
        if let error {
            _ = takeProcessed()
            finishPhoto(.failure(error))
            return
        }
        switch takeProcessed() {
        case .success(let data):
            finishPhoto(.success(data))
        case .failure(let error):
            finishPhoto(.failure(error))
        case nil:
            finishPhoto(.failure(CameraError.noImage))
        }
    }

    private func storeProcessed(_ result: Result<Data, Error>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard photoContinuation != nil else { return }
        processedPhoto = result
    }

    private func takeProcessed() -> Result<Data, Error>? {
        stateLock.lock()
        let result = processedPhoto
        processedPhoto = nil
        stateLock.unlock()
        return result
    }

    private func finishPhoto(_ result: Result<Data, Error>) {
        stateLock.lock()
        let continuation = photoContinuation
        photoContinuation = nil
        processedPhoto = nil
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
                // Allow the long exposure by raising the maximum frame duration,
                // but do not pin the camera at that slow rate. A locked 1 fps
                // rate makes AVCapturePhotoOutput fail the next still with
                // "The operation could not be completed."
                device.activeVideoMaxFrameDuration = slowest.maxFrameDuration
                device.activeVideoMinFrameDuration = slowest.minFrameDuration
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
            // 1.0 is infinity. Leave this lock in place for every frame in the series.
            let gate = NSLock()
            var started = false
            let startExposure = { [weak self] in
                gate.lock()
                let shouldStart = !started
                started = true
                gate.unlock()
                guard shouldStart, let self else {
                    if !shouldStart { return }
                    device.unlockForConfiguration()
                    completion(.failure(CameraError.configurationFailed("The camera went away.")))
                    return
                }
                self.sessionQueue.async {
                    self.applyExposure(on: device, completion: completion)
                }
            }
            device.setFocusModeLocked(lensPosition: 1.0) { _ in
                startExposure()
            }
            // If the lens never reports that it locked, still take the series
            // at the longest exposure. Do not fail the capture for that.
            sessionQueue.asyncAfter(deadline: .now() + 3) {
                startExposure()
            }
        } else {
            // This camera cannot lock the lens at 1.0. Still use the longest exposure.
            applyExposure(on: device, completion: completion)
        }
    }

    private func applyExposure(
        on device: AVCaptureDevice,
        completion: @escaping (Result<TimeInterval, Error>) -> Void
    ) {
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
        // A JPEG format dictionary plus maxPhotoDimensions fails on device with
        // AVFoundationErrorDomain -11800, "The operation could not be completed."
        let settings = AVCapturePhotoSettings()
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
