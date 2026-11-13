import Foundation

/// Clockwise rotation of a camera buffer into the orientation the connection asks for.
public enum FrameOrientation {
    public static func normalizedClockwise(_ degrees: Int) -> Int {
        let wrapped = ((degrees % 360) + 360) % 360
        switch wrapped {
        case 90, 180, 270:
            return wrapped
        default:
            return 0
        }
    }

    public static func size(width: Int, height: Int, clockwise degrees: Int) -> (width: Int, height: Int) {
        switch normalizedClockwise(degrees) {
        case 90, 270:
            return (height, width)
        default:
            return (width, height)
        }
    }

    /// Source pixel that lands on `(x, y)` after a clockwise rotation.
    /// `width` and `height` are the buffer's size before rotation.
    public static func source(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        clockwise degrees: Int
    ) -> (x: Int, y: Int) {
        switch normalizedClockwise(degrees) {
        case 90:
            return (y, height - 1 - x)
        case 180:
            return (width - 1 - x, height - 1 - y)
        case 270:
            return (width - 1 - y, x)
        default:
            return (x, y)
        }
    }
}
