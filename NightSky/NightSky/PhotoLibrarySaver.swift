import Photos
import UIKit

enum PhotoSaveError: LocalizedError {
    case permissionDenied
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photo access is off. Allow MyNightSky to add photos in Settings."
        case .encodeFailed:
            return "The stacked photo could not be encoded."
        }
    }
}

enum PhotoLibrarySaver {
    static func save(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoSaveError.permissionDenied
        }
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw PhotoSaveError.encodeFailed
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}
