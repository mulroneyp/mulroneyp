import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Shared JPEG encoding + drag/drop loading for user-attached Field Guide and Life List photos.
enum UserPhotoImport {
    /// Compresses a decoded image to JPEG for on-device / iCloud storage.
    static func jpeg(from image: UIImage, quality: CGFloat = 0.88) -> (data: Data, width: Int, height: Int)? {
        let width = max(1, Int(image.size.width.rounded()))
        let height = max(1, Int(image.size.height.rounded()))
        guard let data = image.jpegData(compressionQuality: quality) else { return nil }
        return (data, width, height)
    }

    static func jpeg(from data: Data, quality: CGFloat = 0.88) -> (data: Data, width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, quality: quality)
    }

    /// Reads image bytes from a security-scoped or plain file URL (Finder / Files drops).
    static func jpeg(fromFileURL url: URL, quality: CGFloat = 0.88) -> (data: Data, width: Int, height: Int)? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return jpeg(from: data, quality: quality)
    }

    /// Loads image payloads from drag-and-drop item providers (Photos, Files, Safari, etc.).
    @MainActor
    static func jpegs(from providers: [NSItemProvider], quality: CGFloat = 0.88) async -> [Data] {
        var results: [Data] = []
        for provider in providers {
            if let jpeg = await jpeg(from: provider, quality: quality) {
                results.append(jpeg)
            }
        }
        return results
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
struct UserPhotoDropTarget: ViewModifier {
    @Binding var isTargeted: Bool
    var enabled: Bool = true
    var onJPEG: ([Data]) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && isTargeted {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(GuideColor.green, lineWidth: 3)
                        .background(GuideColor.green.opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [.image, .jpeg, .png, .heic, .fileURL],
                isTargeted: enabled ? $isTargeted : .constant(false)
            ) { providers in
                guard enabled else { return false }
                Task { @MainActor in
                    onJPEG(await UserPhotoImport.jpegs(from: providers))
                }
                return true
            }
    }
}

extension View {
    /// Accepts dropped photos and reports JPEG payloads (Field Guide + Life List).
    func userPhotoDrop(
        isTargeted: Binding<Bool>,
        enabled: Bool = true,
        onJPEG: @escaping ([Data]) -> Void
    ) -> some View {
        modifier(UserPhotoDropTarget(isTargeted: isTargeted, enabled: enabled, onJPEG: onJPEG))
    }
}
