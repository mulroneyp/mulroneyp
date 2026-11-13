import CoreVideo
import NightSkyStack
import UIKit

enum ImageEncoding {
    /// Decode a captured photo, honor its orientation, and shrink the long edge.
    static func frameBuffer(data: Data, maxEdge: Int) throws -> FrameBuffer {
        guard let image = UIImage(data: data) else { throw CameraError.noImage }
        return try frameBuffer(from: image, maxEdge: maxEdge)
    }

    /// Copy a BGRA video frame, rotate it for display, and shrink the long edge.
    static func frameBuffer(
        from pixelBuffer: CVPixelBuffer,
        maxEdge: Int,
        rotationDegrees: Int,
        mirrored: Bool = false
    ) throws -> FrameBuffer {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferIsPlanar(pixelBuffer) == false
        else { throw CameraError.noImage }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw CameraError.noImage
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw CameraError.noImage }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard srcW > 0, srcH > 0, bytesPerRow >= srcW * 4 else { throw CameraError.noImage }

        let rotated = FrameOrientation.size(width: srcW, height: srcH, clockwise: rotationDegrees)
        let longest = max(rotated.width, rotated.height)
        let limit = max(1, maxEdge)
        let scale = longest > limit ? Double(limit) / Double(longest) : 1
        let outW = max(1, Int((Double(rotated.width) * scale).rounded()))
        let outH = max(1, Int((Double(rotated.height) * scale).rounded()))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: outW * outH * 3)

        for oy in 0..<outH {
            let ry0 = oy * rotated.height / outH
            let ry1 = max(ry0 + 1, (oy + 1) * rotated.height / outH)
            for ox in 0..<outW {
                let rx0 = ox * rotated.width / outW
                let rx1 = max(rx0 + 1, (ox + 1) * rotated.width / outW)
                var sr = 0
                var sg = 0
                var sb = 0
                var n = 0
                for ry in ry0..<ry1 {
                    for rx in rx0..<rx1 {
                        let flippedX = mirrored ? (rotated.width - 1 - rx) : rx
                        let source = FrameOrientation.source(
                            x: flippedX,
                            y: ry,
                            width: srcW,
                            height: srcH,
                            clockwise: rotationDegrees
                        )
                        let sx = min(max(source.x, 0), srcW - 1)
                        let sy = min(max(source.y, 0), srcH - 1)
                        let offset = sy * bytesPerRow + sx * 4
                        sb += Int(pixels[offset])
                        sg += Int(pixels[offset + 1])
                        sr += Int(pixels[offset + 2])
                        n += 1
                    }
                }
                let dest = (oy * outW + ox) * 3
                rgb[dest] = UInt8(sr / n)
                rgb[dest + 1] = UInt8(sg / n)
                rgb[dest + 2] = UInt8(sb / n)
            }
        }
        return try FrameBuffer.make(width: outW, height: outH, pixels: rgb)
    }

    static func frameBuffer(from image: UIImage, maxEdge: Int) throws -> FrameBuffer {
        let pixelWidth = max(image.size.width * image.scale, 1)
        let pixelHeight = max(image.size.height * image.scale, 1)
        let longest = max(pixelWidth, pixelHeight)
        let scale = longest > CGFloat(maxEdge) ? CGFloat(maxEdge) / longest : 1
        let width = max(1, Int((pixelWidth * scale).rounded()))
        let height = max(1, Int((pixelHeight * scale).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let rendered = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgImage = rendered.cgImage else { throw CameraError.noImage }
        return try rgbBuffer(from: cgImage)
    }

    static func image(from frame: FrameBuffer) -> UIImage? {
        let width = frame.width
        let height = frame.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = frame.pixels[i * 3]
            rgba[i * 4 + 1] = frame.pixels[i * 3 + 1]
            rgba[i * 4 + 2] = frame.pixels[i * 3 + 2]
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func rgbBuffer(from cgImage: CGImage) throws -> FrameBuffer {
        guard let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw CameraError.noImage
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let byteOrder = cgImage.bitmapInfo.intersection(.byteOrderMask)
        let alpha = cgImage.alphaInfo
        // iOS image renderers are little-endian BGRA (premultiplied first).
        let bgra = byteOrder == .byteOrder32Little && (
            alpha == .premultipliedFirst || alpha == .noneSkipFirst || alpha == .first
        )
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * bytesPerRow + x * 4
                let red: UInt8
                let green: UInt8
                let blue: UInt8
                if bgra {
                    blue = bytes[source]
                    green = bytes[source + 1]
                    red = bytes[source + 2]
                } else {
                    red = bytes[source]
                    green = bytes[source + 1]
                    blue = bytes[source + 2]
                }
                let dest = (y * width + x) * 3
                rgb[dest] = red
                rgb[dest + 1] = green
                rgb[dest + 2] = blue
            }
        }
        return try FrameBuffer.make(width: width, height: height, pixels: rgb)
    }
}
