import XCTest
@testable import NightSkyStack

final class StarAlignmentTests: XCTestCase {
    func testDetectsStarsAndIgnoresTheSky() throws {
        let frame = try paint(size: 32, stars: [(10, 12, 255), (20, 18, 180)], sky: 8)
        let stars = detectStars(frame)
        XCTAssertEqual(stars.count, 2)
        XCTAssertEqual(stars[0].x, 10, accuracy: 0.01)
        XCTAssertEqual(stars[0].y, 12, accuracy: 0.01)
        XCTAssertEqual(stars[1].x, 20, accuracy: 0.01)
        XCTAssertEqual(stars[1].y, 18, accuracy: 0.01)
        XCTAssertTrue(stars[0].brightness > stars[1].brightness)
    }

    func testAFlatFrameHasNoStars() throws {
        let frame = try solid(16, 16, 12, 14, 18)
        XCTAssertTrue(detectStars(frame).isEmpty)
    }

    func testStarAlignmentRecoversAShift() throws {
        let reference = try paint(size: 48, stars: [(12, 14, 255), (30, 16, 220), (18, 34, 200)])
        let moved = try paint(size: 48, stars: [(17, 11, 255), (35, 13, 220), (23, 31, 200)])
        let alignment = try XCTUnwrap(alignOnStars(reference: reference, frame: moved, maxShift: 20))
        XCTAssertEqual(alignment.tx, 5, accuracy: 0.05)
        XCTAssertEqual(alignment.ty, -3, accuracy: 0.05)
        XCTAssertEqual(alignment.rotation, 0, accuracy: 0.001)
        for star in [(12.0, 14.0), (30.0, 16.0), (18.0, 34.0)] {
            let point = alignment.framePoint(x: star.0, y: star.1)
            XCTAssertEqual(point.x, star.0 + 5, accuracy: 0.05)
            XCTAssertEqual(point.y, star.1 - 3, accuracy: 0.05)
        }
    }

    func testStarAlignmentRecoversASmallRotation() throws {
        let center = (x: 40.0, y: 40.0)
        let originals = [(16.0, 40.0), (58.0, 22.0), (60.0, 58.0)]
        let radians = 4.0 * Double.pi / 180
        let rotated = originals.map { rotate($0, around: center, radians: radians) }
        let reference = try paint(size: 80, stars: originals.map { (Int($0.0.rounded()), Int($0.1.rounded()), 255) })
        let frame = try paint(size: 80, stars: rotated.map { (Int($0.0.rounded()), Int($0.1.rounded()), 255) })
        let alignment = try XCTUnwrap(alignOnStars(reference: reference, frame: frame, maxShift: 24))
        XCTAssertEqual(alignment.rotation * 180 / .pi, 4, accuracy: 0.35)
        for (original, expected) in zip(originals, rotated) {
            let point = alignment.framePoint(x: original.0, y: original.1)
            XCTAssertEqual(point.x, expected.0, accuracy: 0.75)
            XCTAssertEqual(point.y, expected.1, accuracy: 0.75)
        }
    }

    func testAHotPixelDoesNotPullTheStarsApart() throws {
        var moved = try paint(size: 64, stars: [(15, 18, 240), (40, 22, 230), (22, 44, 210)])
        let hot = (50 * 64 + 48) * 3
        moved = try replacePixel(moved, index: hot, value: 255)
        let reference = try paint(size: 64, stars: [(10, 20, 240), (35, 24, 230), (17, 46, 210)])
        let alignment = try XCTUnwrap(alignOnStars(reference: reference, frame: moved, maxShift: 20))
        XCTAssertEqual(alignment.tx, 5, accuracy: 0.2)
        XCTAssertEqual(alignment.ty, -2, accuracy: 0.2)
        let point = alignment.framePoint(x: 10, y: 20)
        XCTAssertEqual(point.x, 15, accuracy: 0.2)
        XCTAssertEqual(point.y, 18, accuracy: 0.2)
    }

    func testStackedStarsStaySharpWhenTheFieldRotates() throws {
        let center = (x: 32.0, y: 32.0)
        let originals = [(12.0, 32.0), (48.0, 18.0), (50.0, 46.0)]
        let radians = 3.0 * Double.pi / 180
        let rotated = originals.map { rotate($0, around: center, radians: radians) }
        let reference = try paint(size: 64, stars: originals.map { (Int($0.0.rounded()), Int($0.1.rounded()), 255) })
        let frame = try paint(size: 64, stars: rotated.map { (Int($0.0.rounded()), Int($0.1.rounded()), 255) })
        let options = AlignmentOptions(searchRadius: 24, coarseMaxEdge: 64, fineStride: 1)
        let stacked = try stackAligned([reference, frame], options: options, mode: .mean)
        let unaligned = try stackFrames([reference, frame], translations: [.zero, .zero], mode: .mean)
        let star = (x: Int(originals[0].0.rounded()), y: Int(originals[0].1.rounded()))
        XCTAssertGreaterThan(stacked.pixel(x: star.x, y: star.y).r, unaligned.pixel(x: star.x, y: star.y).r)
        XCTAssertGreaterThan(stacked.pixel(x: star.x, y: star.y).r, 200)
    }
}

private func paint(size: Int, stars: [(Int, Int, Int)], sky: UInt8 = 0) throws -> FrameBuffer {
    var pixels = [UInt8](repeating: sky, count: size * size * 3)
    for star in stars {
        guard star.0 >= 0, star.1 >= 0, star.0 < size, star.1 < size else { continue }
        let index = (star.1 * size + star.0) * 3
        let value = UInt8(min(255, star.2))
        pixels[index] = value
        pixels[index + 1] = value
        pixels[index + 2] = value
    }
    return try FrameBuffer.make(width: size, height: size, pixels: pixels)
}

private func replacePixel(_ frame: FrameBuffer, index: Int, value: UInt8) throws -> FrameBuffer {
    var pixels = frame.pixels
    pixels[index] = value
    pixels[index + 1] = value
    pixels[index + 2] = value
    return try FrameBuffer.make(width: frame.width, height: frame.height, pixels: pixels)
}

private func rotate(
    _ point: (Double, Double),
    around center: (x: Double, y: Double),
    radians: Double
) -> (Double, Double) {
    let dx = point.0 - center.x
    let dy = point.1 - center.y
    let cosine = cos(radians)
    let sine = sin(radians)
    return (
        center.x + cosine * dx - sine * dy,
        center.y + sine * dx + cosine * dy
    )
}
