import XCTest
@testable import NightSkyStack

final class AlignmentTests: XCTestCase {
    func testIdenticalFramesStayAtZero() throws {
        let frame = try solid(8, 8, 20, 30, 40)
        let shift = try estimateTranslation(
            reference: frame,
            frame: frame,
            options: AlignmentOptions(searchRadius: 3, coarseMaxEdge: 64)
        )
        XCTAssertEqual(shift, .zero)
    }

    func testFindsHorizontalShift() throws {
        let reference = try starField(size: 7, x: 3, y: 3)
        let moved = try starField(size: 7, x: 5, y: 3)
        let shift = try estimateTranslation(
            reference: reference,
            frame: moved,
            options: AlignmentOptions(searchRadius: 3, coarseMaxEdge: 64)
        )
        XCTAssertEqual(shift, Translation(dx: 2, dy: 0))
    }

    func testFindsVerticalShift() throws {
        let reference = try starField(size: 7, x: 3, y: 4)
        let moved = try starField(size: 7, x: 3, y: 2)
        let shift = try estimateTranslation(
            reference: reference,
            frame: moved,
            options: AlignmentOptions(searchRadius: 3, coarseMaxEdge: 64)
        )
        XCTAssertEqual(shift, Translation(dx: 0, dy: -2))
    }

    func testZeroRadiusSkipsTheSearch() throws {
        let reference = try starField(size: 5, x: 2, y: 2)
        let moved = try starField(size: 5, x: 3, y: 2)
        let shift = try estimateTranslation(
            reference: reference,
            frame: moved,
            options: AlignmentOptions(searchRadius: 0)
        )
        XCTAssertEqual(shift, .zero)
    }

    func testMismatchedSizesThrow() throws {
        let a = try solid(4, 4, 0, 0, 0)
        let b = try solid(5, 4, 0, 0, 0)
        XCTAssertThrowsError(try estimateTranslation(reference: a, frame: b)) { error in
            XCTAssertEqual(error as? StackError, .inconsistentDimensions)
        }
    }

    func testCoarseSearchFindsALargerShift() throws {
        let reference = try block(size: 64, originX: 16, originY: 20, side: 8)
        let moved = try block(size: 64, originX: 24, originY: 20, side: 8)
        let shift = try estimateTranslation(
            reference: reference,
            frame: moved,
            options: AlignmentOptions(searchRadius: 16, coarseMaxEdge: 16, fineStride: 1)
        )
        XCTAssertEqual(shift, Translation(dx: 8, dy: 0))
    }

    func testSolidDownscaleKeepsTheColor() throws {
        let frame = try solid(8, 6, 10, 20, 30)
        let small = frame.scaled(maxEdge: 4)
        XCTAssertEqual(small.width, 4)
        XCTAssertEqual(small.height, 3)
        for y in 0..<small.height {
            for x in 0..<small.width {
                XCTAssertEqual(small.pixel(x: x, y: y).r, 10)
                XCTAssertEqual(small.pixel(x: x, y: y).g, 20)
                XCTAssertEqual(small.pixel(x: x, y: y).b, 30)
            }
        }
    }
}

func solid(_ width: Int, _ height: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) throws -> FrameBuffer {
    var pixels = [UInt8](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) {
        pixels[i * 3] = r
        pixels[i * 3 + 1] = g
        pixels[i * 3 + 2] = b
    }
    return try FrameBuffer.make(width: width, height: height, pixels: pixels)
}

func starField(size: Int, x: Int, y: Int) throws -> FrameBuffer {
    var pixels = [UInt8](repeating: 0, count: size * size * 3)
    let i = (y * size + x) * 3
    pixels[i] = 255
    pixels[i + 1] = 255
    pixels[i + 2] = 255
    return try FrameBuffer.make(width: size, height: size, pixels: pixels)
}

func block(size: Int, originX: Int, originY: Int, side: Int) throws -> FrameBuffer {
    var pixels = [UInt8](repeating: 0, count: size * size * 3)
    for y in originY..<(originY + side) {
        for x in originX..<(originX + side) {
            let i = (y * size + x) * 3
            pixels[i] = 240
            pixels[i + 1] = 240
            pixels[i + 2] = 240
        }
    }
    return try FrameBuffer.make(width: size, height: size, pixels: pixels)
}
