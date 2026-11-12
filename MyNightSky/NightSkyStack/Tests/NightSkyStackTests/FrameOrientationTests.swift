import XCTest
@testable import NightSkyStack

final class FrameOrientationTests: XCTestCase {
    func testZeroAndOutOfRangeStayUpright() {
        XCTAssertEqual(FrameOrientation.normalizedClockwise(0), 0)
        XCTAssertEqual(FrameOrientation.normalizedClockwise(360), 0)
        XCTAssertEqual(FrameOrientation.normalizedClockwise(-90), 270)
        XCTAssertEqual(FrameOrientation.normalizedClockwise(45), 0)
        XCTAssertEqual(FrameOrientation.size(width: 2, height: 3, clockwise: 0).width, 2)
        XCTAssertEqual(FrameOrientation.size(width: 2, height: 3, clockwise: 0).height, 3)
        XCTAssertEqual(FrameOrientation.source(x: 1, y: 2, width: 2, height: 3, clockwise: 0).x, 1)
        XCTAssertEqual(FrameOrientation.source(x: 1, y: 2, width: 2, height: 3, clockwise: 0).y, 2)
    }

    func testQuarterTurnsMapTheCorners() {
        XCTAssertEqual(FrameOrientation.size(width: 2, height: 3, clockwise: 90).width, 3)
        XCTAssertEqual(FrameOrientation.size(width: 2, height: 3, clockwise: 90).height, 2)
        // 90° clockwise: top-left of the rotated image is the source bottom-left.
        XCTAssertEqual(FrameOrientation.source(x: 0, y: 0, width: 2, height: 3, clockwise: 90).x, 0)
        XCTAssertEqual(FrameOrientation.source(x: 0, y: 0, width: 2, height: 3, clockwise: 90).y, 2)
        // Source top-left lands on the rotated top-right.
        XCTAssertEqual(FrameOrientation.source(x: 2, y: 0, width: 2, height: 3, clockwise: 90).x, 0)
        XCTAssertEqual(FrameOrientation.source(x: 2, y: 0, width: 2, height: 3, clockwise: 90).y, 0)

        XCTAssertEqual(FrameOrientation.source(x: 0, y: 0, width: 2, height: 3, clockwise: 180).x, 1)
        XCTAssertEqual(FrameOrientation.source(x: 0, y: 0, width: 2, height: 3, clockwise: 180).y, 2)

        XCTAssertEqual(FrameOrientation.size(width: 2, height: 3, clockwise: 270).width, 3)
        XCTAssertEqual(FrameOrientation.size(width: 2, height: 3, clockwise: 270).height, 2)
        // 270° clockwise: top-left of the rotated image is the source top-right.
        XCTAssertEqual(FrameOrientation.source(x: 0, y: 0, width: 2, height: 3, clockwise: 270).x, 1)
        XCTAssertEqual(FrameOrientation.source(x: 0, y: 0, width: 2, height: 3, clockwise: 270).y, 0)
    }
}
