import XCTest
@testable import NightSkyStack

final class SeriesTimelineTests: XCTestCase {
    func testFrameCountClampsAndDefaultsToTen() {
        XCTAssertEqual(SeriesTimeline.defaultFrameCount, 10)
        XCTAssertEqual(SeriesTimeline(frameCount: 10).frameCount, 10)
        XCTAssertEqual(SeriesTimeline(frameCount: 1).frameCount, 2)
        XCTAssertEqual(SeriesTimeline(frameCount: 100).frameCount, 30)
    }

    func testExposureDoesNotStartUntilTheCountdownFinishes() {
        var timeline = SeriesTimeline(frameCount: 10, countdownSeconds: 10)
        timeline.startCountdown()
        XCTAssertEqual(timeline.phase, .countdown(secondsRemaining: 10))
        XCTAssertFalse(timeline.exposureMayBegin)

        for expected in stride(from: 9, through: 1, by: -1) {
            XCTAssertFalse(timeline.tickCountdown())
            XCTAssertEqual(timeline.phase, .countdown(secondsRemaining: expected))
            XCTAssertFalse(timeline.exposureMayBegin)
            timeline.noteFrameCaptured()
            XCTAssertEqual(timeline.framesCompleted, 0)
            XCTAssertFalse(timeline.beginStacking())
        }

        XCTAssertTrue(timeline.tickCountdown())
        XCTAssertTrue(timeline.exposureMayBegin)
        XCTAssertEqual(timeline.phase, .capturing(framesCompleted: 0, frameCount: 10))
    }

    func testShorterCountdownStillGatesExposure() {
        var timeline = SeriesTimeline(frameCount: 4, countdownSeconds: 3)
        timeline.startCountdown()
        XCTAssertFalse(timeline.tickCountdown())
        XCTAssertFalse(timeline.tickCountdown())
        XCTAssertTrue(timeline.tickCountdown())
        XCTAssertEqual(timeline.framesRemaining, 4)
    }

    func testCaptureClockUsesTheReportedExposure() {
        var timeline = SeriesTimeline(frameCount: 10)
        timeline.startCountdown()
        XCTAssertTrue(repeatTicks(10, on: &timeline))
        let start = Date(timeIntervalSince1970: 1_000)
        timeline.noteCaptureStarted(at: start)
        XCTAssertEqual(timeline.elapsed(at: start.addingTimeInterval(12.4)), 12.4, accuracy: 0.001)

        timeline.exposureDuration = 0.5
        let estimateAtStart = Date(timeIntervalSince1970: 1_500)
        XCTAssertEqual(timeline.estimatedTimeRemaining(at: estimateAtStart) ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(timeline.framesRemaining, 10)
        XCTAssertFalse(timeline.isWaitingBetweenFrames)

        let mark = Date(timeIntervalSince1970: 2_000)
        for _ in 0..<4 {
            timeline.noteFrameCaptured(at: mark)
        }
        XCTAssertEqual(timeline.framesCompleted, 4)
        XCTAssertEqual(timeline.framesRemaining, 6)
        XCTAssertTrue(timeline.isWaitingBetweenFrames)
        XCTAssertEqual(timeline.estimatedTimeRemaining(at: mark) ?? -1, 33, accuracy: 0.001)
        XCTAssertEqual(timeline.gapTimeRemaining(at: mark.addingTimeInterval(2)) ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(timeline.estimatedTimeRemaining(at: mark.addingTimeInterval(2)) ?? -1, 31, accuracy: 0.001)
        XCTAssertNil(SeriesTimeline(frameCount: 10).estimatedTimeRemaining(at: estimateAtStart))
    }

    func testFiveSecondGapBetweenFramesAndNoneAfterTheLast() {
        var timeline = SeriesTimeline(frameCount: 2, countdownSeconds: 1)
        timeline.startCountdown()
        XCTAssertTrue(timeline.tickCountdown())
        timeline.exposureDuration = 1
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(SeriesTimeline.interFrameGap, 5, accuracy: 0.001)
        XCTAssertEqual(timeline.estimatedTimeRemaining(at: start) ?? -1, 7, accuracy: 0.001)
        XCTAssertNil(timeline.gapTimeRemaining(at: start))

        timeline.noteFrameCaptured(at: start)
        XCTAssertTrue(timeline.isWaitingBetweenFrames)
        XCTAssertEqual(timeline.framesRemaining, 1)
        XCTAssertEqual(timeline.gapTimeRemaining(at: start) ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(timeline.estimatedTimeRemaining(at: start) ?? -1, 6, accuracy: 0.001)
        XCTAssertEqual(timeline.estimatedTimeRemaining(at: start.addingTimeInterval(2)) ?? -1, 4, accuracy: 0.001)

        timeline.noteGapFinished()
        XCTAssertFalse(timeline.isWaitingBetweenFrames)
        XCTAssertEqual(timeline.estimatedTimeRemaining(at: start.addingTimeInterval(5)) ?? -1, 1, accuracy: 0.001)

        timeline.noteFrameCaptured(at: start.addingTimeInterval(6))
        XCTAssertFalse(timeline.isWaitingBetweenFrames)
        XCTAssertEqual(timeline.framesRemaining, 0)
        XCTAssertNil(timeline.gapTimeRemaining(at: start.addingTimeInterval(6)))
        XCTAssertNil(timeline.estimatedTimeRemaining(at: start.addingTimeInterval(6)))
        XCTAssertTrue(timeline.beginStacking())
    }

    func testCaptureStartIsIgnoredDuringCountdown() {
        var timeline = SeriesTimeline(frameCount: 5, countdownSeconds: 2)
        timeline.startCountdown()
        timeline.noteCaptureStarted(at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(timeline.elapsed(at: Date(timeIntervalSince1970: 80)), 0)
        XCTAssertNil(timeline.estimatedTimeRemaining(at: Date(timeIntervalSince1970: 80)))
    }

    func testStackingWaitsForEveryFrame() {
        var timeline = SeriesTimeline(frameCount: 3, countdownSeconds: 1)
        timeline.startCountdown()
        XCTAssertTrue(timeline.tickCountdown())
        timeline.noteFrameCaptured()
        timeline.noteFrameCaptured()
        XCTAssertFalse(timeline.beginStacking())
        timeline.noteFrameCaptured()
        XCTAssertTrue(timeline.beginStacking())
        XCTAssertEqual(timeline.phase, .stacking(frameCount: 3))
        timeline.noteFrameCaptured()
        XCTAssertEqual(timeline.phase, .stacking(frameCount: 3))
        timeline.finishPreview()
        XCTAssertEqual(timeline.phase, .preview)
    }

    func testResetClearsTheSeries() {
        var timeline = SeriesTimeline(frameCount: 6, countdownSeconds: 1)
        timeline.startCountdown()
        XCTAssertTrue(timeline.tickCountdown())
        timeline.exposureDuration = 1
        timeline.noteCaptureStarted(at: Date())
        timeline.noteFrameCaptured(at: Date())
        XCTAssertTrue(timeline.isWaitingBetweenFrames)
        timeline.fail("Stopped")
        XCTAssertEqual(timeline.phase, .failed("Stopped"))
        timeline.reset()
        XCTAssertEqual(timeline.phase, .ready)
        XCTAssertNil(timeline.exposureDuration)
        XCTAssertEqual(timeline.elapsed(at: Date()), 0)
        XCTAssertFalse(timeline.isWaitingBetweenFrames)
    }
}

private func repeatTicks(_ count: Int, on timeline: inout SeriesTimeline) -> Bool {
    var finished = false
    for _ in 0..<count {
        finished = timeline.tickCountdown()
    }
    return finished
}
