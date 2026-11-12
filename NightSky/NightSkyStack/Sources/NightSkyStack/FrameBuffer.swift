public struct FrameBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// RGB, row-major, one byte per channel. `pixels.count == width * height * 3`.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "Frame size must be positive")
        precondition(pixels.count == width * height * 3, "RGB buffer has the wrong length")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public static func make(width: Int, height: Int, pixels: [UInt8]) throws -> FrameBuffer {
        guard width > 0, height > 0 else { throw StackError.emptyFrame }
        guard pixels.count == width * height * 3 else { throw StackError.inconsistentDimensions }
        return FrameBuffer(width: width, height: height, pixels: pixels)
    }

    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 3
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    func offset(x: Int, y: Int) -> Int {
        (y * width + x) * 3
    }

    /// Box-filter downscale. The longer edge becomes `maxEdge` when the image is larger.
    func scaled(maxEdge: Int) -> FrameBuffer {
        precondition(maxEdge >= 1)
        let longest = max(width, height)
        if longest <= maxEdge { return self }
        let newW = max(1, Int(Double(width) * Double(maxEdge) / Double(longest)))
        let newH = max(1, Int(Double(height) * Double(maxEdge) / Double(longest)))
        var out = [UInt8](repeating: 0, count: newW * newH * 3)
        for y in 0..<newH {
            let y0 = y * height / newH
            let y1 = max(y0 + 1, (y + 1) * height / newH)
            for x in 0..<newW {
                let x0 = x * width / newW
                let x1 = max(x0 + 1, (x + 1) * width / newW)
                var sr = 0
                var sg = 0
                var sb = 0
                var n = 0
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let i = (yy * width + xx) * 3
                        sr += Int(pixels[i])
                        sg += Int(pixels[i + 1])
                        sb += Int(pixels[i + 2])
                        n += 1
                    }
                }
                let o = (y * newW + x) * 3
                out[o] = UInt8(sr / n)
                out[o + 1] = UInt8(sg / n)
                out[o + 2] = UInt8(sb / n)
            }
        }
        return FrameBuffer(width: newW, height: newH, pixels: out)
    }

    func luminancePlane() -> [UInt8] {
        var plane = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 3
            let y = (Int(pixels[o]) * 77 + Int(pixels[o + 1]) * 150 + Int(pixels[o + 2]) * 29) >> 8
            plane[i] = UInt8(y)
        }
        return plane
    }
}
