import ImageIO
import SwiftUI
import UIKit

enum BundleImages {
    private static let fullCache = NSCache<NSString, UIImage>()
    private static let thumbCache = NSCache<NSString, UIImage>()

    /// Full-resolution decode for detail / zoom. Cached by path.
    static func image(for relativePath: String) -> UIImage? {
        let key = relativePath as NSString
        if let cached = fullCache.object(forKey: key) {
            return cached
        }
        guard let url = url(for: relativePath),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        fullCache.setObject(image, forKey: key)
        return image
    }

    /// Downsampled decode for list rows. `maxPixelSize` is the longest edge in pixels
    /// (pass ~pointSize × screen scale). Avoids decoding 900–1000px JPEGs for 44–88pt thumbs.
    static func thumbnail(for relativePath: String, maxPixelSize: CGFloat) -> UIImage? {
        let capped = max(1, Int(maxPixelSize.rounded()))
        let key = "\(relativePath)#\(capped)" as NSString
        if let cached = thumbCache.object(forKey: key) {
            return cached
        }
        guard let url = url(for: relativePath),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: capped,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Fallback if ImageIO cannot thumbnail this file.
            return image(for: relativePath)
        }
        let image = UIImage(cgImage: cgImage)
        thumbCache.setObject(image, forKey: key)
        return image
    }

    static func url(for relativePath: String) -> URL? {
        let file = (relativePath as NSString).lastPathComponent
        let directory = (relativePath as NSString).deletingLastPathComponent
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory),
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/\(directory)"),
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.url(forResource: file, withExtension: nil, subdirectory: directory),
        ]
        return candidates.compactMap { $0 }.first
    }
}

struct BundlePhoto: View {
    var path: String
    var alt: String
    var fills: Bool = false
    /// When set, decode a downsampled thumbnail instead of the full JPEG.
    var maxPixelSize: CGFloat? = nil

    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
                    .accessibilityLabel(alt)
            } else if loadFailed {
                GuideColor.green.opacity(0.12)
                    .frame(height: maxPixelSize == nil ? 160 : nil)
                    .overlay {
                        if maxPixelSize == nil {
                            Text("Photo missing")
                                .font(.caption)
                                .foregroundStyle(GuideColor.muted)
                        }
                    }
            } else {
                GuideColor.green.opacity(0.12)
                    .overlay {
                        if maxPixelSize == nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            }
        }
        .background(GuideColor.green.opacity(0.08))
        .task(id: taskID) {
            await loadImage()
        }
    }

    private var taskID: String {
        if let maxPixelSize {
            return "\(path)#\(Int(maxPixelSize.rounded()))"
        }
        return path
    }

    @MainActor
    private func loadImage() async {
        loadFailed = false
        image = nil
        let path = path
        let maxPixelSize = maxPixelSize
        let loaded = await Task.detached(priority: .utility) {
            if let maxPixelSize {
                return BundleImages.thumbnail(for: path, maxPixelSize: maxPixelSize)
            }
            return BundleImages.image(for: path)
        }.value
        if let loaded {
            image = loaded
        } else {
            loadFailed = true
        }
    }
}
