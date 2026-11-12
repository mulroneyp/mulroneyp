/// Shift of a frame relative to the reference.
/// A feature at `(x, y)` in the reference appears at `(x + dx, y + dy)` in the frame.
/// Sampling the aligned frame at reference coordinate `(x, y)` reads the frame at `(x + dx, y + dy)`.
public struct Translation: Equatable, Sendable {
    public var dx: Int
    public var dy: Int

    public init(dx: Int, dy: Int) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = Translation(dx: 0, dy: 0)
}

public struct AlignmentOptions: Equatable, Sendable {
    /// Maximum shift to search, in full-resolution pixels.
    public var searchRadius: Int
    /// Longest edge of the coarse image used to find the shift.
    public var coarseMaxEdge: Int
    /// Pixel stride of the full-resolution refinement search.
    public var fineStride: Int

    public init(searchRadius: Int = 32, coarseMaxEdge: Int = 192, fineStride: Int = 2) {
        self.searchRadius = max(0, searchRadius)
        self.coarseMaxEdge = max(8, coarseMaxEdge)
        self.fineStride = max(1, fineStride)
    }
}

public func estimateTranslation(
    reference: FrameBuffer,
    frame: FrameBuffer,
    options: AlignmentOptions = AlignmentOptions()
) throws -> Translation {
    guard reference.width == frame.width, reference.height == frame.height else {
        throw StackError.inconsistentDimensions
    }
    guard reference.width > 0, reference.height > 0 else { throw StackError.emptyFrame }
    if options.searchRadius == 0 { return .zero }

    let longest = max(reference.width, reference.height)
    if longest <= options.coarseMaxEdge {
        return searchTranslation(
            reference: reference.luminancePlane(),
            frame: frame.luminancePlane(),
            width: reference.width,
            height: reference.height,
            center: .zero,
            radius: options.searchRadius,
            sampleStride: 1
        )
    }

    let coarseReference = reference.scaled(maxEdge: options.coarseMaxEdge)
    let coarseFrame = frame.scaled(maxEdge: options.coarseMaxEdge)
    let scaleX = Double(reference.width) / Double(coarseReference.width)
    let scaleY = Double(reference.height) / Double(coarseReference.height)
    let coarseRadius = max(
        1,
        Int((Double(options.searchRadius) / min(scaleX, scaleY)).rounded(.up))
    )
    let coarse = searchTranslation(
        reference: coarseReference.luminancePlane(),
        frame: coarseFrame.luminancePlane(),
        width: coarseReference.width,
        height: coarseReference.height,
        center: .zero,
        radius: coarseRadius,
        sampleStride: 1
    )
    let center = Translation(
        dx: Int((Double(coarse.dx) * scaleX).rounded()),
        dy: Int((Double(coarse.dy) * scaleY).rounded())
    )
    let fineRadius = max(1, Int(max(scaleX, scaleY).rounded(.up)))
    return searchTranslation(
        reference: reference.luminancePlane(),
        frame: frame.luminancePlane(),
        width: reference.width,
        height: reference.height,
        center: center,
        radius: fineRadius,
        sampleStride: options.fineStride
    )
}

func searchTranslation(
    reference: [UInt8],
    frame: [UInt8],
    width: Int,
    height: Int,
    center: Translation,
    radius: Int,
    sampleStride: Int
) -> Translation {
    let step = max(1, sampleStride)
    var sampleCount = 0
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            sampleCount += 1
            x += step
        }
        y += step
    }
    let minCount = max(1, sampleCount / 2)

    var best = center
    var bestScore = Int64.max
    var bestDistance = Int.max

    let yStart = center.dy - radius
    let yEnd = center.dy + radius
    let xStart = center.dx - radius
    let xEnd = center.dx + radius

    for dy in yStart...yEnd {
        for dx in xStart...xEnd {
            var error: Int64 = 0
            var count = 0
            var py = 0
            while py < height {
                let fy = py + dy
                if fy >= 0 && fy < height {
                    var px = 0
                    while px < width {
                        let fx = px + dx
                        if fx >= 0 && fx < width {
                            let rv = Int(reference[py * width + px])
                            let fv = Int(frame[fy * width + fx])
                            error += Int64(abs(rv - fv))
                            count += 1
                        }
                        px += step
                    }
                }
                py += step
            }
            if count < minCount { continue }
            let score = error * 1_000_000 / Int64(count)
            let distance = abs(dx - center.dx) + abs(dy - center.dy)
            let betterScore = score < bestScore
            let tieCloserToCenter = score == bestScore && distance < bestDistance
            if betterScore || tieCloserToCenter {
                bestScore = score
                bestDistance = distance
                best = Translation(dx: dx, dy: dy)
            }
        }
    }

    if bestScore == Int64.max { return .zero }
    return best
}
