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
    /// Pause after each frame except the last. There is no pause before the first frame.
    public static let interFrameGap: TimeInterval = 5

    public private(set) var phase: SeriesPhase
    public let frameCount: Int
    public let countdownSeconds: Int
    /// Longest exposure the camera reported for the active format, in seconds.
    /// Passed in from AVFoundation. This type does not choose a shutter speed.
    public var exposureDuration: TimeInterval?
    public private(set) var captureStartedAt: Date?
    /// Set when a frame has finished and another frame still has to be taken.
    private var gapStartedAt: Date?

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

    /// True during the 5 second pause between frames. False after the last frame.
    public var isWaitingBetweenFrames: Bool {
        gapStartedAt != nil
    }

    public mutating func startCountdown() {
        captureStartedAt = nil
        gapStartedAt = nil
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

    /// Time left in the current between-frame pause. Nil when a frame is being exposed.
    public func gapTimeRemaining(at now: Date) -> TimeInterval? {
        guard let gapStartedAt else { return nil }
        let left = Self.interFrameGap - now.timeIntervalSince(gapStartedAt)
        guard left > 0 else { return nil }
        return left
    }

    /// Remaining time for exposures still to take, plus the pauses between them.
    /// The pause before a later frame is included. There is no pause after the last frame.
    public func estimatedTimeRemaining(at now: Date) -> TimeInterval? {
        guard exposureMayBegin, let exposureDuration, exposureDuration > 0 else { return nil }
        let frames = framesRemaining
        guard frames > 0 else { return nil }
        let futureGaps = TimeInterval(frames - 1) * Self.interFrameGap
        let exposureTime = TimeInterval(frames) * exposureDuration
        let currentGapLeft = gapTimeRemaining(at: now) ?? 0
        return currentGapLeft + exposureTime + futureGaps
    }

    public mutating func noteFrameCaptured(at date: Date = Date()) {
        guard case .capturing(let done, let total) = phase else { return }
        let next = min(total, done + 1)
        phase = .capturing(framesCompleted: next, frameCount: total)
        gapStartedAt = next < total ? date : nil
    }

    public mutating func noteGapFinished() {
        gapStartedAt = nil
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
        gapStartedAt = nil
    }
}
