import Foundation

/// A star found in one frame. `x` and `y` are pixel coordinates.
public struct Star: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var brightness: Double

    public init(x: Double, y: Double, brightness: Double) {
        self.x = x
        self.y = y
        self.brightness = brightness
    }
}

/// Maps a reference pixel onto another frame: a rotation about the origin, then a shift.
/// A reference point `(x, y)` is read from the frame at `framePoint(x:y:)`.
public struct StarAlignment: Equatable, Sendable {
    public var rotation: Double
    public var tx: Double
    public var ty: Double

    public init(rotation: Double, tx: Double, ty: Double) {
        self.rotation = rotation
        self.tx = tx
        self.ty = ty
    }

    public static let identity = StarAlignment(rotation: 0, tx: 0, ty: 0)

    public func framePoint(x: Double, y: Double) -> (x: Double, y: Double) {
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return (cosine * x - sine * y + tx, sine * x + cosine * y + ty)
    }
}

/// Bright peaks that stand above the sky. The brightest stars come first.
public func detectStars(_ frame: FrameBuffer, maxCount: Int = 40) -> [Star] {
    let width = frame.width
    let height = frame.height
    guard width >= 3, height >= 3, maxCount > 0 else { return [] }
    let plane = frame.luminancePlane()
    let background = skyBackground(plane)
    let threshold = background + 16

    var peaks: [Star] = []
    peaks.reserveCapacity(maxCount)
    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            let value = Int(plane[y * width + x])
            guard value >= threshold else { continue }
            guard isLocalPeak(plane, width: width, x: x, y: y, value: value) else { continue }
            let center = centroid(plane, width: width, height: height, x: x, y: y, background: background)
            peaks.append(Star(x: center.x, y: center.y, brightness: center.brightness))
        }
    }

    peaks.sort { $0.brightness > $1.brightness }
    var kept: [Star] = []
    kept.reserveCapacity(min(maxCount, peaks.count))
    for star in peaks {
        let crowded = kept.contains { existing in
            let dx = existing.x - star.x
            let dy = existing.y - star.y
            return dx * dx + dy * dy < 16
        }
        if crowded { continue }
        kept.append(star)
        if kept.count == maxCount { break }
    }
    return kept
}

/// Star registration of `frame` onto `reference`.
/// Nil when either frame has no stars that can be matched within `maxShift`.
public func alignOnStars(
    reference: FrameBuffer,
    frame: FrameBuffer,
    maxShift: Double = 48
) throws -> StarAlignment? {
    guard reference.width == frame.width, reference.height == frame.height else {
        throw StackError.inconsistentDimensions
    }
    guard maxShift > 0 else { return nil }
    let referenceStars = detectStars(reference)
    let frameStars = detectStars(frame)
    guard !referenceStars.isEmpty, !frameStars.isEmpty else { return nil }
    let pairs = matchStarPairs(
        reference: referenceStars,
        frame: frameStars,
        maxShift: maxShift
    )
    guard !pairs.isEmpty else { return nil }
    return fitStarAlignment(pairs)
}

private func skyBackground(_ plane: [UInt8]) -> Int {
    guard !plane.isEmpty else { return 0 }
    let stride = max(1, plane.count / 4096)
    var samples: [Int] = []
    samples.reserveCapacity(plane.count / stride)
    var index = 0
    while index < plane.count {
        samples.append(Int(plane[index]))
        index += stride
    }
    samples.sort()
    return samples[samples.count / 2]
}

private func isLocalPeak(_ plane: [UInt8], width: Int, x: Int, y: Int, value: Int) -> Bool {
    for dy in -1...1 {
        for dx in -1...1 {
            if dx == 0 && dy == 0 { continue }
            if Int(plane[(y + dy) * width + (x + dx)]) >= value { return false }
        }
    }
    return true
}

private func centroid(
    _ plane: [UInt8],
    width: Int,
    height: Int,
    x: Int,
    y: Int,
    background: Int
) -> (x: Double, y: Double, brightness: Double) {
    var weightSum = 0.0
    var xSum = 0.0
    var ySum = 0.0
    var peak = 0.0
    for dy in -1...1 {
        let yy = y + dy
        guard yy >= 0 && yy < height else { continue }
        for dx in -1...1 {
            let xx = x + dx
            guard xx >= 0 && xx < width else { continue }
            let weight = Double(Int(plane[yy * width + xx]) - background)
            guard weight > 0 else { continue }
            weightSum += weight
            xSum += Double(xx) * weight
            ySum += Double(yy) * weight
            if weight > peak { peak = weight }
        }
    }
    guard weightSum > 0 else {
        return (Double(x), Double(y), Double(plane[y * width + x]))
    }
    return (xSum / weightSum, ySum / weightSum, peak)
}

private func matchStarPairs(
    reference: [Star],
    frame: [Star],
    maxShift: Double
) -> [(reference: Star, frame: Star)] {
    let gate = min(16.0, max(2.0, maxShift))
    var best: [(reference: Star, frame: Star)] = []
    var bestShift = Double.greatestFiniteMagnitude

    for anchorRef in reference.prefix(12) {
        for anchorFrame in frame.prefix(12) {
            let tx = anchorFrame.x - anchorRef.x
            let ty = anchorFrame.y - anchorRef.y
            let shift = (tx * tx + ty * ty).squareRoot()
            if shift > maxShift { continue }

            var used = Set<Int>()
            var inliers: [(reference: Star, frame: Star)] = []
            for ref in reference {
                var bestIndex: Int?
                var bestDistance = gate
                for (index, candidate) in frame.enumerated() where !used.contains(index) {
                    let dx = candidate.x - (ref.x + tx)
                    let dy = candidate.y - (ref.y + ty)
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance <= bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
                if let bestIndex {
                    used.insert(bestIndex)
                    inliers.append((ref, frame[bestIndex]))
                }
            }

            let betterCount = inliers.count > best.count
            let sameCountCloser = inliers.count == best.count && inliers.count > 0 && shift < bestShift
            if betterCount || sameCountCloser {
                best = inliers
                bestShift = shift
            }
        }
    }
    return best
}

private func fitStarAlignment(_ pairs: [(reference: Star, frame: Star)]) -> StarAlignment {
    let translation = translationOnly(pairs)
    guard pairs.count >= 2, let similarity = similarityFit(pairs) else { return translation }
    if similarityResidual(similarity, pairs) + 0.05 >= translationResidual(translation, pairs) {
        return translation
    }
    let kept = pairs.filter { residual(similarity, $0) <= 4 }
    guard kept.count >= 2, kept.count < pairs.count, let refit = similarityFit(kept) else {
        return similarity
    }
    if similarityResidual(refit, kept) <= similarityResidual(similarity, kept) {
        return refit
    }
    return similarity
}

private func translationOnly(_ pairs: [(reference: Star, frame: Star)]) -> StarAlignment {
    var tx = 0.0
    var ty = 0.0
    for pair in pairs {
        tx += pair.frame.x - pair.reference.x
        ty += pair.frame.y - pair.reference.y
    }
    let count = Double(pairs.count)
    return StarAlignment(rotation: 0, tx: tx / count, ty: ty / count)
}

/// Small-angle fit: frame ≈ reference + (-θ y, θ x) + (tx, ty).
private func similarityFit(_ pairs: [(reference: Star, frame: Star)]) -> StarAlignment? {
    var meanX = 0.0
    var meanY = 0.0
    for pair in pairs {
        meanX += pair.reference.x
        meanY += pair.reference.y
    }
    meanX /= Double(pairs.count)
    meanY /= Double(pairs.count)

    var s1 = 0.0
    var s2 = 0.0
    var s3 = 0.0
    var b0 = 0.0
    var b1 = 0.0
    var b2 = 0.0
    for pair in pairs {
        let rx = pair.reference.x - meanX
        let ry = pair.reference.y - meanY
        let dx = pair.frame.x - pair.reference.x
        let dy = pair.frame.y - pair.reference.y
        s1 += rx
        s2 += -ry
        s3 += rx * rx + ry * ry
        b0 += dx
        b1 += dy
        b2 += -ry * dx + rx * dy
    }
    let n = Double(pairs.count)
    guard let solved = solve3(
        [
            [n, 0, s2],
            [0, n, s1],
            [s2, s1, s3],
        ],
        [b0, b1, b2]
    ) else { return nil }

    let txPrime = solved[0]
    let tyPrime = solved[1]
    let theta = solved[2]
    return StarAlignment(
        rotation: theta,
        tx: txPrime + theta * meanY,
        ty: tyPrime - theta * meanX
    )
}

private func solve3(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
    var a = matrix
    var b = rhs
    for column in 0..<3 {
        var pivot = column
        for row in (column + 1)..<3 where abs(a[row][column]) > abs(a[pivot][column]) {
            pivot = row
        }
        if abs(a[pivot][column]) < 1e-8 { return nil }
        if pivot != column {
            a.swapAt(pivot, column)
            b.swapAt(pivot, column)
        }
        let divisor = a[column][column]
        for index in column..<3 {
            a[column][index] /= divisor
        }
        b[column] /= divisor
        for row in 0..<3 where row != column {
            let factor = a[row][column]
            if factor == 0 { continue }
            for index in column..<3 {
                a[row][index] -= factor * a[column][index]
            }
            b[row] -= factor * b[column]
        }
    }
    return b
}

private func translationResidual(
    _ alignment: StarAlignment,
    _ pairs: [(reference: Star, frame: Star)]
) -> Double {
    similarityResidual(alignment, pairs)
}

private func similarityResidual(
    _ alignment: StarAlignment,
    _ pairs: [(reference: Star, frame: Star)]
) -> Double {
    guard !pairs.isEmpty else { return 0 }
    var sum = 0.0
    for pair in pairs {
        sum += residual(alignment, pair)
    }
    return (sum / Double(pairs.count)).squareRoot()
}

private func residual(
    _ alignment: StarAlignment,
    _ pair: (reference: Star, frame: Star)
) -> Double {
    let point = alignment.framePoint(x: pair.reference.x, y: pair.reference.y)
    let dx = point.x - pair.frame.x
    let dy = point.y - pair.frame.y
    return dx * dx + dy * dy
}
