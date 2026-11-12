import Foundation

public enum SeriesPhase: Equatable, Sendable {
    case ready
    case countdown(secondsRemaining: Int)
    case capturing(framesCompleted: Int, frameCount: Int)
    case stacking(frameCount: Int)
    case preview
    case failed(String)
}

/// Countdown and capture progress. Exposure is allowed only in `.capturing`.
public struct SeriesTimeline: Equatable, Sendable {
    public static let defaultFrameCount = 10
    public static let minimumFrameCount = 2
    public static let maximumFrameCount = 30
    public static let countdownSeconds = 10

    public private(set) var phase: SeriesPhase
    public let frameCount: Int
    public let countdownSeconds: Int
    /// Longest exposure the camera reported for the active format, in seconds.
    /// Passed in from AVFoundation. This type does not choose a shutter speed.
    public var exposureDuration: TimeInterval?
    public private(set) var captureStartedAt: Date?

    public init(frameCount: Int, countdownSeconds: Int = SeriesTimeline.countdownSeconds) {
        self.frameCount = min(max(frameCount, Self.minimumFrameCount), Self.maximumFrameCount)
        self.countdownSeconds = max(1, countdownSeconds)
        self.phase = .ready
    }

    /// True only after the countdown has finished and the frame series may start.
    public var exposureMayBegin: Bool {
        if case .capturing = phase { return true }
        return false
    }

    public var framesCompleted: Int {
        if case .capturing(let done, _) = phase { return done }
        return 0
    }

    public var framesRemaining: Int {
        guard case .capturing(let done, let total) = phase else { return 0 }
        return max(0, total - done)
    }

    public mutating func startCountdown() {
        captureStartedAt = nil
        phase = .countdown(secondsRemaining: countdownSeconds)
    }

    /// Advances the countdown by one second.
    /// Returns true on the tick that finishes the countdown and opens `.capturing`.
    public mutating func tickCountdown() -> Bool {
        guard case .countdown(let remaining) = phase else { return false }
        if remaining > 1 {
            phase = .countdown(secondsRemaining: remaining - 1)
            return false
        }
        phase = .capturing(framesCompleted: 0, frameCount: frameCount)
        return true
    }

    public mutating func noteCaptureStarted(at date: Date) {
        guard exposureMayBegin else { return }
        if captureStartedAt == nil {
            captureStartedAt = date
        }
    }

    public func elapsed(at now: Date) -> TimeInterval {
        guard let captureStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(captureStartedAt))
    }

    /// Remaining capture time from the camera-reported exposure and frames still to take.
    public var estimatedTimeRemaining: TimeInterval? {
        guard exposureMayBegin, let exposureDuration, exposureDuration > 0 else { return nil }
        return exposureDuration * Double(framesRemaining)
    }

    public mutating func noteFrameCaptured() {
        guard case .capturing(let done, let total) = phase else { return }
        phase = .capturing(framesCompleted: min(total, done + 1), frameCount: total)
    }

    @discardableResult
    public mutating func beginStacking() -> Bool {
        guard case .capturing(let done, let total) = phase, done == total else { return false }
        phase = .stacking(frameCount: total)
        return true
    }

    public mutating func finishPreview() {
        phase = .preview
    }

    public mutating func fail(_ message: String) {
        phase = .failed(message)
    }

    public mutating func reset() {
        phase = .ready
        exposureDuration = nil
        captureStartedAt = nil
    }
}
