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

/// Rear-camera stills at the active format's longest exposure.
///
/// The earlier still path failed on device with AVFoundationErrorDomain -11800
/// ("The operation could not be completed") after the first photo. The photo
/// output's default settings keep still-image stabilization on and only prepare
/// that pipeline. The next still then fails inside the photo output. This class
/// turns stabilization off, prepares matching settings once, and waits until
/// `captureReadiness` is `.ready` before every `capturePhoto`.
final class CameraCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "nightsky.camera")
    private let stateLock = NSLock()
    private var device: AVCaptureDevice?
    private var exposureSeconds: TimeInterval = 1
    private var settingsTemplate: AVCapturePhotoSettings?
    private var pendingStill: PendingStill?
    private var processedPhoto: Result<Data, Error>?
    private var nextStillID = 0

    private struct PendingStill {
        let id: Int
        let continuation: CheckedContinuation<Data, Error>
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

    /// Switches the running session to the format's longest exposure and prepares
    /// the still pipeline. The first photo is taken after this returns.
    func beginLongExposure() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.applyLongExposure(completion: continuation.resume(with:))
            }
        }
    }

    func captureFrame(maxEdge: Int) async throws -> FrameBuffer {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.beginStill(continuation: continuation)
            }
        }
        return try ImageEncoding.frameBuffer(data: data, maxEdge: maxEdge)
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.finishStill(.failure(CancellationError()))
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.session.beginConfiguration()
                for input in self.session.inputs {
                    self.session.removeInput(input)
                }
                if self.session.outputs.contains(where: { $0 === self.photoOutput }) {
                    self.session.removeOutput(self.photoOutput)
                }
                self.session.commitConfiguration()
                self.device = nil
                self.settingsTemplate = nil
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
        if let error {
            _ = takeProcessed()
            finishStill(.failure(error))
            return
        }
        switch takeProcessed() {
        case .success(let data):
            finishStill(.success(data))
        case .failure(let error):
            finishStill(.failure(error))
        case nil:
            finishStill(.failure(CameraError.noImage))
        }
    }

    private func beginStill(continuation: CheckedContinuation<Data, Error>) {
        stateLock.lock()
        if pendingStill != nil {
            stateLock.unlock()
            continuation.resume(throwing: CameraError.configurationFailed("A capture is already in progress."))
            return
        }
        nextStillID += 1
        let stillID = nextStillID
        pendingStill = PendingStill(id: stillID, continuation: continuation)
        processedPhoto = nil
        stateLock.unlock()

        let timeout = exposureSeconds + 20
        sessionQueue.asyncAfter(deadline: .now() + timeout) {
            self.failStill(id: stillID, CameraError.configurationFailed("The camera did not return a frame."))
        }
        waitUntilCaptureReady(id: stillID, attempts: 200)
    }

    private func waitUntilCaptureReady(id: Int, attempts: Int) {
        stateLock.lock()
        let live = pendingStill?.id == id
        stateLock.unlock()
        guard live else { return }
        if photoOutput.captureReadiness == .ready || attempts <= 0 {
            if photoOutput.captureReadiness == .ready {
                shoot(id: id)
            } else {
                failStill(id: id, CameraError.configurationFailed("The camera was not ready for the next still."))
            }
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + 0.05) {
            self.waitUntilCaptureReady(id: id, attempts: attempts - 1)
        }
    }

    private func shoot(id: Int) {
        stateLock.lock()
        let live = pendingStill?.id == id
        stateLock.unlock()
        guard live else { return }
        let settings = AVCapturePhotoSettings(from: settingsTemplate ?? makeTemplateSettings())
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func failStill(id: Int, _ error: Error) {
        stateLock.lock()
        guard let pending = pendingStill, pending.id == id else {
            stateLock.unlock()
            return
        }
        pendingStill = nil
        processedPhoto = nil
        stateLock.unlock()
        pending.continuation.resume(throwing: error)
    }

    private func finishStill(_ result: Result<Data, Error>) {
        stateLock.lock()
        let pending = pendingStill
        pendingStill = nil
        processedPhoto = nil
        stateLock.unlock()
        pending?.continuation.resume(with: result)
    }

    private func storeProcessed(_ result: Result<Data, Error>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard pendingStill != nil else { return }
        processedPhoto = result
    }

    private func takeProcessed() -> Result<Data, Error>? {
        stateLock.lock()
        let result = processedPhoto
        processedPhoto = nil
        stateLock.unlock()
        return result
    }

    private func configureAndStart() throws {
        stateLock.lock()
        pendingStill = nil
        processedPhoto = nil
        stateLock.unlock()
        settingsTemplate = nil

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
        if session.outputs.contains(where: { $0 === photoOutput }) {
            session.removeOutput(photoOutput)
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

        guard session.canAddOutput(photoOutput) else {
            commit()
            throw CameraError.configurationFailed("Could not use the photo output.")
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .speed
        if photoOutput.isFastCapturePrioritizationSupported {
            photoOutput.isFastCapturePrioritizationEnabled = false
        }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = false
        }
        if let dimensions = choosePhotoDimensions(format.supportedMaxPhotoDimensions) {
            photoOutput.maxPhotoDimensions = dimensions
        }
        if let connection = photoOutput.connection(with: .video),
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

    /// Let the shutter be as long as `duration` without locking the camera at that
    /// slow rate. A frame rate locked near 1 fps makes the next still fail with -11800.
    private func allowLongExposure(_ duration: CMTime, on device: AVCaptureDevice) {
        let currentMin = device.activeVideoMinFrameDuration
        if currentMin.isValid && CMTimeCompare(currentMin, duration) > 0 {
            device.activeVideoMinFrameDuration = duration
        }
        device.activeVideoMaxFrameDuration = duration
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
        allowLongExposure(duration, on: device)

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
            guard case .success(let seconds) = result else {
                completion(result)
                return
            }
            self.exposureSeconds = seconds
            self.prepareStills { prepareResult in
                switch prepareResult {
                case .success:
                    completion(.success(seconds))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }

        let startExposure = { [weak self] in
            gate.lock()
            let alreadyFinished = finished
            gate.unlock()
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

    /// The photo output's default prepared settings enable still-image stabilization.
    /// That pipeline is what fails the next still with -11800 after a manual exposure.
    private func prepareStills(completion: @escaping (Result<Void, Error>) -> Void) {
        let template = makeTemplateSettings()
        settingsTemplate = template
        photoOutput.setPreparedPhotoSettingsArray([template]) { prepared, error in
            self.sessionQueue.async {
                if let error {
                    completion(.failure(CameraError.configurationFailed(error.localizedDescription)))
                    return
                }
                guard prepared else {
                    completion(.failure(CameraError.configurationFailed("The camera could not prepare a still.")))
                    return
                }
                completion(.success(()))
            }
        }
    }

    private func makeTemplateSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        settings.photoQualityPrioritization = .speed
        // Default is true on devices that support it. Left on, it overrides the
        // manual exposure and the next still fails with "The operation could not be completed."
        if photoOutput.isStillImageStabilizationSupported {
            settings.isAutoStillImageStabilizationEnabled = false
        }
        return settings
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
        let withStills = usable.filter { !$0.supportedMaxPhotoDimensions.isEmpty }
        let pool = withStills.isEmpty ? usable : withStills
        guard let best = pool.max(by: { lhs, rhs in
            let order = CMTimeCompare(self.longestExposure(for: lhs), self.longestExposure(for: rhs))
            if order != 0 { return order < 0 }
            let stillOrder = self.stillPixels(lhs) - self.stillPixels(rhs)
            if stillOrder != 0 { return stillOrder < 0 }
            return self.videoPixels(lhs) < self.videoPixels(rhs)
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

    private func videoPixels(_ format: AVCaptureDevice.Format) -> Int {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dims.width) * Int(dims.height)
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
