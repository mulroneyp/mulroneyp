import SwiftUI
import UIKit

enum BundleImages {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for relativePath: String) -> UIImage? {
        let key = relativePath as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let url = url(for: relativePath),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func url(for relativePath: String) -> URL? {
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

    var body: some View {
        Group {
            if let image = BundleImages.image(for: path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
                    .accessibilityLabel(alt)
            } else {
                GuideColor.green.opacity(0.12)
                    .frame(height: 160)
                    .overlay {
                        Text("Photo missing")
                            .font(.caption)
                            .foregroundStyle(GuideColor.muted)
                    }
            }
        }
        .background(GuideColor.green.opacity(0.08))
    }
}
