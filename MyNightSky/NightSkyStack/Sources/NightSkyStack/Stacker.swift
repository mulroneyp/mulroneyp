import Foundation

public enum StackMode: Equatable, Sendable {
    /// Average of the aligned samples. Hot pixels fade but remain.
    case mean
    /// Middle sample of the aligned values. A single hot pixel drops out.
    case median
}

public enum StackError: Error, Equatable, LocalizedError, Sendable {
    case noFrames
    case emptyFrame
    case inconsistentDimensions
    case translationCountMismatch

    public var errorDescription: String? {
        switch self {
        case .noFrames:
            return "There are no frames to stack."
        case .emptyFrame:
            return "A frame was empty."
        case .inconsistentDimensions:
            return "Frames must all be the same size."
        case .translationCountMismatch:
            return "Each frame needs one alignment."
        }
    }
}

public func stackFrames(
    _ frames: [FrameBuffer],
    translations: [Translation],
    mode: StackMode
) throws -> FrameBuffer {
    guard let reference = frames.first else { throw StackError.noFrames }
    guard frames.count == translations.count else { throw StackError.translationCountMismatch }
    for frame in frames where frame.width != reference.width || frame.height != reference.height {
        throw StackError.inconsistentDimensions
    }

    let width = reference.width
    let height = reference.height
    var output = [UInt8](repeating: 0, count: width * height * 3)
    var reds: [UInt8] = []
    var greens: [UInt8] = []
    var blues: [UInt8] = []
    reds.reserveCapacity(frames.count)
    greens.reserveCapacity(frames.count)
    blues.reserveCapacity(frames.count)

    for y in 0..<height {
        for x in 0..<width {
            reds.removeAll(keepingCapacity: true)
            greens.removeAll(keepingCapacity: true)
            blues.removeAll(keepingCapacity: true)
            for (frame, shift) in zip(frames, translations) {
                let sx = x + shift.dx
                let sy = y + shift.dy
                guard frame.contains(x: sx, y: sy) else { continue }
                let i = frame.offset(x: sx, y: sy)
                reds.append(frame.pixels[i])
                greens.append(frame.pixels[i + 1])
                blues.append(frame.pixels[i + 2])
            }
            let o = (y * width + x) * 3
            output[o] = combine(reds, mode: mode)
            output[o + 1] = combine(greens, mode: mode)
            output[o + 2] = combine(blues, mode: mode)
        }
    }
    return FrameBuffer(width: width, height: height, pixels: output)
}

/// Align every frame to the first on its stars, then stack.
/// The reference frame is not moved. A frame with no matching stars falls back
/// to a whole-image translation.
public func stackAligned(
    _ frames: [FrameBuffer],
    options: AlignmentOptions = AlignmentOptions(),
    mode: StackMode = .median
) throws -> FrameBuffer {
    guard let reference = frames.first else { throw StackError.noFrames }
    var alignments: [StarAlignment] = [.identity]
    alignments.reserveCapacity(frames.count)
    for frame in frames.dropFirst() {
        if let starAlignment = try alignOnStars(
            reference: reference,
            frame: frame,
            maxShift: Double(options.searchRadius)
        ) {
            alignments.append(starAlignment)
        } else {
            let shift = try estimateTranslation(reference: reference, frame: frame, options: options)
            alignments.append(StarAlignment(rotation: 0, tx: Double(shift.dx), ty: Double(shift.dy)))
        }
    }
    return try stackStars(frames, alignments: alignments, mode: mode)
}

func stackStars(
    _ frames: [FrameBuffer],
    alignments: [StarAlignment],
    mode: StackMode
) throws -> FrameBuffer {
    guard let reference = frames.first else { throw StackError.noFrames }
    guard frames.count == alignments.count else { throw StackError.translationCountMismatch }
    for frame in frames where frame.width != reference.width || frame.height != reference.height {
        throw StackError.inconsistentDimensions
    }

    let width = reference.width
    let height = reference.height
    var output = [UInt8](repeating: 0, count: width * height * 3)
    var reds: [UInt8] = []
    var greens: [UInt8] = []
    var blues: [UInt8] = []
    reds.reserveCapacity(frames.count)
    greens.reserveCapacity(frames.count)
    blues.reserveCapacity(frames.count)

    for y in 0..<height {
        for x in 0..<width {
            reds.removeAll(keepingCapacity: true)
            greens.removeAll(keepingCapacity: true)
            blues.removeAll(keepingCapacity: true)
            for (frame, alignment) in zip(frames, alignments) {
                let source = alignment.framePoint(x: Double(x), y: Double(y))
                guard let sample = sampleBilinear(frame, x: source.x, y: source.y) else { continue }
                reds.append(sample.r)
                greens.append(sample.g)
                blues.append(sample.b)
            }
            let offset = (y * width + x) * 3
            output[offset] = combine(reds, mode: mode)
            output[offset + 1] = combine(greens, mode: mode)
            output[offset + 2] = combine(blues, mode: mode)
        }
    }
    return FrameBuffer(width: width, height: height, pixels: output)
}

func sampleBilinear(_ frame: FrameBuffer, x: Double, y: Double) -> (r: UInt8, g: UInt8, b: UInt8)? {
    let maxX = Double(frame.width - 1)
    let maxY = Double(frame.height - 1)
    guard x >= 0, y >= 0, x <= maxX, y <= maxY else { return nil }
    let x0 = Int(x)
    let y0 = Int(y)
    let x1 = min(x0 + 1, frame.width - 1)
    let y1 = min(y0 + 1, frame.height - 1)
    let tx = x - Double(x0)
    let ty = y - Double(y0)
    let topLeft = frame.pixel(x: x0, y: y0)
    let topRight = frame.pixel(x: x1, y: y0)
    let bottomLeft = frame.pixel(x: x0, y: y1)
    let bottomRight = frame.pixel(x: x1, y: y1)
    return (
        r: blend(topLeft.r, topRight.r, bottomLeft.r, bottomRight.r, tx: tx, ty: ty),
        g: blend(topLeft.g, topRight.g, bottomLeft.g, bottomRight.g, tx: tx, ty: ty),
        b: blend(topLeft.b, topRight.b, bottomLeft.b, bottomRight.b, tx: tx, ty: ty)
    )
}

private func blend(
    _ topLeft: UInt8,
    _ topRight: UInt8,
    _ bottomLeft: UInt8,
    _ bottomRight: UInt8,
    tx: Double,
    ty: Double
) -> UInt8 {
    let top = Double(topLeft) + (Double(topRight) - Double(topLeft)) * tx
    let bottom = Double(bottomLeft) + (Double(bottomRight) - Double(bottomLeft)) * tx
    let value = top + (bottom - top) * ty
    return UInt8(min(255, max(0, value.rounded())))
}

func combine(_ samples: [UInt8], mode: StackMode) -> UInt8 {
    guard !samples.isEmpty else { return 0 }
    switch mode {
    case .mean:
        let sum = samples.reduce(0) { $0 + Int($1) }
        return UInt8((sum + samples.count / 2) / samples.count)
    case .median:
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return UInt8((Int(sorted[mid - 1]) + Int(sorted[mid])) / 2)
    }
}
