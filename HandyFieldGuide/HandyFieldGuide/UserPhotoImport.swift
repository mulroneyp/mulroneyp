import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Shared JPEG encode, downscale, drag/drop, and paste loading for user-attached
/// Field Guide and Life List photos.
enum UserPhotoImport {
    /// Longest edge after downscale — phone camera originals are far larger than needed.
    static let maxPixel: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.82

    /// Drag-and-drop is the iPad / Mac path; iPhone uses paste (and the Photos picker).
    static var supportsDrop: Bool {
        UIDevice.current.userInterfaceIdiom != .phone
    }

    /// Paste from Photos Copy is the iPhone path (drag-and-drop is unreliable there).
    static var supportsPaste: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    static var pasteboardHasImages: Bool {
        UIPasteboard.general.hasImages
    }

    /// Compresses a decoded image to a downscaled JPEG for on-device / iCloud storage.
    static func jpeg(
        from image: UIImage,
        quality: CGFloat = jpegQuality,
        maxPixel: CGFloat = maxPixel
    ) -> (data: Data, width: Int, height: Int)? {
        let resized = downscaled(image, maxPixel: maxPixel)
        guard let data = resized.jpegData(compressionQuality: quality) else { return nil }
        let width = max(1, Int(resized.size.width.rounded()))
        let height = max(1, Int(resized.size.height.rounded()))
        return (data, width, height)
    }

    static func jpeg(
        from data: Data,
        quality: CGFloat = jpegQuality,
        maxPixel: CGFloat = maxPixel
    ) -> (data: Data, width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, quality: quality, maxPixel: maxPixel)
    }

    /// Reads image bytes from a security-scoped or plain file URL (Finder / Files drops).
    static func jpeg(
        fromFileURL url: URL,
        quality: CGFloat = jpegQuality,
        maxPixel: CGFloat = maxPixel
    ) -> (data: Data, width: Int, height: Int)? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return jpeg(from: data, quality: quality, maxPixel: maxPixel)
    }

    /// Shrinks so the longest edge is at most `maxPixel`, using a scale-1 bitmap
    /// so stored width/height match JPEG pixels.
    static func downscaled(_ image: UIImage, maxPixel: CGFloat = maxPixel) -> UIImage {
        let pixelWidth = max(1, image.size.width * image.scale)
        let pixelHeight = max(1, image.size.height * image.scale)
        let longest = max(pixelWidth, pixelHeight)
        let scaleFactor = longest > maxPixel ? maxPixel / longest : 1
        let target = CGSize(
            width: max(1, (pixelWidth * scaleFactor).rounded()),
            height: max(1, (pixelHeight * scaleFactor).rounded())
        )
        // Already within budget and scale-1 — keep the original decode.
        if scaleFactor == 1, image.scale == 1,
           Int(image.size.width.rounded()) == Int(target.width),
           Int(image.size.height.rounded()) == Int(target.height) {
            return image
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Loads image payloads from drag-and-drop item providers (Photos, Files, Safari, etc.).
    @MainActor
    static func jpegs(from providers: [NSItemProvider], quality: CGFloat = jpegQuality) async -> [Data] {
        var results: [Data] = []
        for provider in providers {
            if let jpeg = await jpeg(from: provider, quality: quality) {
                results.append(jpeg)
            }
        }
        return results
    }

    /// Images currently on the system pasteboard (Photos → Copy, Share → Copy, etc.).
    @MainActor
    static func jpegsFromPasteboard(quality: CGFloat = jpegQuality) -> [Data] {
        let board = UIPasteboard.general
        let images: [UIImage]
        if let many = board.images, !many.isEmpty {
            images = many
        } else if let one = board.image {
            images = [one]
        } else {
            images = []
        }
        return images.compactMap { jpeg(from: $0, quality: quality)?.data }
    }

    @MainActor
    private static func jpeg(from provider: NSItemProvider, quality: CGFloat) async -> Data? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let data = await loadData(provider, type: .image),
               let jpeg = jpeg(from: data, quality: quality)?.data {
                return jpeg
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadFileURL(provider),
               let jpeg = jpeg(fromFileURL: url, quality: quality)?.data {
                return jpeg
            }
        }
        return nil
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Drag-and-drop target for image files / photo library drags onto a bird photo area.
/// Enabled on iPad / Mac only (`UserPhotoImport.supportsDrop`).
struct UserPhotoDropTarget: ViewModifier {
    @Binding var isTargeted: Bool
    var enabled: Bool = true
    var onJPEG: ([Data]) -> Void

    private var dropEnabled: Bool {
        enabled && UserPhotoImport.supportsDrop
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if dropEnabled && isTargeted {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(GuideColor.green, lineWidth: 3)
                        .background(GuideColor.green.opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [.image, .jpeg, .png, .heic, .fileURL],
                isTargeted: dropEnabled ? $isTargeted : .constant(false)
            ) { providers in
                guard dropEnabled else { return false }
                Task { @MainActor in
                    onJPEG(await UserPhotoImport.jpegs(from: providers))
                }
                return true
            }
    }
}

extension View {
    /// Accepts dropped photos and reports JPEG payloads (Field Guide + Life List).
    /// No-op target on iPhone — use paste there instead.
    func userPhotoDrop(
        isTargeted: Binding<Bool>,
        enabled: Bool = true,
        onJPEG: @escaping ([Data]) -> Void
    ) -> some View {
        modifier(UserPhotoDropTarget(isTargeted: isTargeted, enabled: enabled, onJPEG: onJPEG))
    }
}

/// iPhone chip: paste images copied from Photos into a bird record.
struct UserPhotoPasteChip: View {
    var title: String = "Paste photo"
    var expanding: Bool = true
    var onJPEG: ([Data]) -> Void
    var onEmpty: (() -> Void)?

    var body: some View {
        Button {
            let jpegs = UserPhotoImport.jpegsFromPasteboard()
            if jpegs.isEmpty {
                onEmpty?()
            } else {
                onJPEG(jpegs)
            }
        } label: {
            Label(title, systemImage: "doc.on.clipboard")
                .frame(maxWidth: expanding ? .infinity : nil)
        }
        .buttonStyle(GuideChipStyle(selected: true))
        .accessibilityHint("Pastes an image copied from Photos. Large images are resized before saving.")
    }
}
