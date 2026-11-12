import XCTest
@testable import NightSkyStack

final class StackerTests: XCTestCase {
    func testMeanOfIdenticalFramesIsTheFrame() throws {
        let frame = try solid(3, 2, 8, 16, 32)
        let stacked = try stackFrames([frame, frame, frame], translations: [.zero, .zero, .zero], mode: .mean)
        XCTAssertEqual(stacked, frame)
    }

    func testMeanAveragesChannels() throws {
        let dark = try solid(1, 1, 10, 20, 30)
        let bright = try solid(1, 1, 40, 60, 80)
        let stacked = try stackFrames([dark, bright], translations: [.zero, .zero], mode: .mean)
        let pixel = stacked.pixel(x: 0, y: 0)
        XCTAssertEqual(pixel.r, 25)
        XCTAssertEqual(pixel.g, 40)
        XCTAssertEqual(pixel.b, 55)
    }

    func testMeanRoundsHalfUp() throws {
        let a = try solid(1, 1, 0, 0, 0)
        let b = try solid(1, 1, 255, 1, 1)
        let stacked = try stackFrames([a, b], translations: [.zero, .zero], mode: .mean)
        XCTAssertEqual(stacked.pixel(x: 0, y: 0).r, 128)
    }

    func testMedianDropsAHotPixel() throws {
        let a = try solid(1, 1, 10, 11, 12)
        let b = try solid(1, 1, 12, 13, 14)
        let hot = try solid(1, 1, 255, 255, 255)
        let stacked = try stackFrames([a, hot, b], translations: [.zero, .zero, .zero], mode: .median)
        let pixel = stacked.pixel(x: 0, y: 0)
        XCTAssertEqual(pixel.r, 12)
        XCTAssertEqual(pixel.g, 13)
        XCTAssertEqual(pixel.b, 14)
    }

    func testMedianOfEvenCountAveragesTheMiddlePair() throws {
        let values: [UInt8] = [4, 10, 20, 100]
        let frames = try values.map { try solid(1, 1, $0, $0, $0) }
        let stacked = try stackFrames(frames, translations: Array(repeating: .zero, count: frames.count), mode: .median)
        XCTAssertEqual(stacked.pixel(x: 0, y: 0).r, 15)
    }

    func testPartialOverlapUsesOnlyVisibleSamples() throws {
        let reference = try FrameBuffer.make(width: 2, height: 1, pixels: [0, 0, 0, 0, 0, 0])
        let other = try FrameBuffer.make(width: 2, height: 1, pixels: [0, 0, 0, 10, 0, 0])
        let stacked = try stackFrames(
            [reference, other],
            translations: [.zero, Translation(dx: 1, dy: 0)],
            mode: .mean
        )
        XCTAssertEqual(stacked.pixel(x: 0, y: 0).r, 5)
        XCTAssertEqual(stacked.pixel(x: 1, y: 0).r, 0)
    }

    func testAlignedStackPutsTheStarBack() throws {
        let reference = try starField(size: 7, x: 3, y: 3)
        let moved = try starField(size: 7, x: 4, y: 3)
        let options = AlignmentOptions(searchRadius: 2, coarseMaxEdge: 64)
        let stacked = try stackAligned([reference, moved], options: options, mode: .mean)
        XCTAssertEqual(stacked.pixel(x: 3, y: 3).r, 255)
        XCTAssertEqual(stacked.pixel(x: 4, y: 3).r, 0)
    }

    func testUnalignedStackSplitsTheStar() throws {
        let reference = try starField(size: 7, x: 3, y: 3)
        let moved = try starField(size: 7, x: 4, y: 3)
        let stacked = try stackFrames([reference, moved], translations: [.zero, .zero], mode: .mean)
        XCTAssertEqual(stacked.pixel(x: 3, y: 3).r, 128)
        XCTAssertEqual(stacked.pixel(x: 4, y: 3).r, 128)
    }

    func testSingleFrameIsUnchanged() throws {
        let frame = try solid(2, 2, 7, 8, 9)
        let stacked = try stackAligned([frame], mode: .median)
        XCTAssertEqual(stacked, frame)
    }

    func testNoFramesThrows() {
        XCTAssertThrowsError(try stackAligned([])) { error in
            XCTAssertEqual(error as? StackError, .noFrames)
        }
    }

    func testMismatchedFrameSizesThrow() throws {
        let a = try solid(2, 2, 1, 1, 1)
        let b = try solid(3, 2, 1, 1, 1)
        XCTAssertThrowsError(try stackFrames([a, b], translations: [.zero, .zero], mode: .mean)) { error in
            XCTAssertEqual(error as? StackError, .inconsistentDimensions)
        }
    }

    func testTranslationCountMismatchThrows() throws {
        let frame = try solid(2, 2, 1, 1, 1)
        XCTAssertThrowsError(try stackFrames([frame, frame], translations: [.zero], mode: .mean)) { error in
            XCTAssertEqual(error as? StackError, .translationCountMismatch)
        }
    }

    func testRejectedBufferLength() {
        XCTAssertThrowsError(try FrameBuffer.make(width: 2, height: 2, pixels: [1, 2, 3])) { error in
            XCTAssertEqual(error as? StackError, .inconsistentDimensions)
        }
    }
}
