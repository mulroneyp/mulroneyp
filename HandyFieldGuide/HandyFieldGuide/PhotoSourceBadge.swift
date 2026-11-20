import SwiftUI

/// Compact badge for photo origin (library “My photo” vs Field Guide open-licence stock).
/// **My photo** uses a brighter green fill so the badge reads clearly against paper/card;
/// **Stock** keeps the outline-on-card treatment.
struct PhotoSourceBadge: View {
    var source: LifeListPhotoSource
    var compact: Bool = false

    private var isLibrary: Bool { source == .library }

    var body: some View {
        Text(source.badgeTitle)
            .font(compact ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold))
            .tracking(compact ? 0.2 : 0.5)
            .foregroundStyle(isLibrary ? GuideColor.paper : GuideColor.green)
            .padding(.horizontal, compact ? 5 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(
                isLibrary
                    ? GuideColor.myPhotoBadge
                    : GuideColor.card.opacity(compact ? 0.92 : 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(
                        isLibrary ? GuideColor.myPhotoBadge : GuideColor.green.opacity(0.35),
                        lineWidth: 1
                    )
            }
            .accessibilityLabel(source.accessibilityLabel)
    }
}
