import NightSkyStack
import UIKit

enum ImageEncoding {
    /// Decode a captured photo, honor its orientation, and shrink the long edge.
    static func frameBuffer(data: Data, maxEdge: Int) throws -> FrameBuffer {
        guard let image = UIImage(data: data) else { throw CameraError.noImage }
        return try frameBuffer(from: image, maxEdge: maxEdge)
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
