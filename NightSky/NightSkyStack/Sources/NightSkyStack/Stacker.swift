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

/// Align every frame to the first, then stack. The reference frame is not shifted.
public func stackAligned(
    _ frames: [FrameBuffer],
    options: AlignmentOptions = AlignmentOptions(),
    mode: StackMode = .median
) throws -> FrameBuffer {
    guard let reference = frames.first else { throw StackError.noFrames }
    var translations: [Translation] = [.zero]
    translations.reserveCapacity(frames.count)
    for frame in frames.dropFirst() {
        translations.append(try estimateTranslation(reference: reference, frame: frame, options: options))
    }
    return try stackFrames(frames, translations: translations, mode: mode)
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
