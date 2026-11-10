import SwiftUI
import UIKit

/// Pinch-to-zoom and pan for species detail photographs (male, female, or single).
struct ZoomablePhoto: View {
    var path: String
    var alt: String
    var label: String

    @State private var showingViewer = false
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                GeometryReader { geo in
                    ZoomableScrollImage(image: image, accessibilityLabel: alt)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .frame(maxWidth: .infinity)
                .frame(height: viewerHeight(for: image))
                .background(GuideColor.green.opacity(0.08))
                .accessibilityAddTraits(.isImage)
                .overlay(alignment: .bottomTrailing) {
                    Text("Pinch to zoom")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(GuideColor.paper.opacity(0.88))
                        .foregroundStyle(GuideColor.muted)
                        .padding(8)
                        .allowsHitTesting(false)
                }
                .onLongPressGesture(minimumDuration: 0.35) {
                    showingViewer = true
                }
            } else if loadFailed {
                GuideColor.green.opacity(0.12)
                    .frame(height: 160)
                    .overlay {
                        Text("Photo missing")
                            .font(.caption)
                            .foregroundStyle(GuideColor.muted)
                    }
            } else {
                GuideColor.green.opacity(0.12)
                    .frame(height: 220)
                    .overlay { ProgressView() }
            }
        }
        .task(id: path) {
            loadFailed = false
            image = nil
            let path = path
            let loaded = await Task.detached(priority: .userInitiated) {
                BundleImages.image(for: path)
            }.value
            if let loaded {
                image = loaded
            } else {
                loadFailed = true
            }
        }
        .fullScreenCover(isPresented: $showingViewer) {
            if let image {
                ZoomablePhotoViewer(image: image, title: label, alt: alt) {
                    showingViewer = false
                }
            }
        }
    }

    private func viewerHeight(for image: UIImage) -> CGFloat {
        let aspect = image.size.height / max(image.size.width, 1)
        // Keep male/female photos usable in the scroll view without eating the whole screen.
        return min(max(220, 320 * aspect), 420)
    }
}

struct ZoomablePhotoViewer: View {
    var image: UIImage
    var title: String
    var alt: String
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ZoomableScrollImage(image: image, accessibilityLabel: alt, maximumZoom: 8)
                    .ignoresSafeArea()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

/// UIScrollView-backed zoom so pinch and pan feel native and work for every photo.
struct ZoomableScrollImage: UIViewRepresentable {
    var image: UIImage
    var accessibilityLabel: String
    var maximumZoom: CGFloat = 5

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = maximumZoom
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.onBoundsChange = { [weak coordinator = context.coordinator] in
            coordinator?.layoutImage(resetZoom: false)
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityLabel = accessibilityLabel
        imageView.tag = 100
        scroll.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        let imageChanged = context.coordinator.image !== image
        context.coordinator.image = image
        context.coordinator.maximumZoom = maximumZoom
        if let imageView = scroll.viewWithTag(100) as? UIImageView {
            imageView.image = image
            imageView.accessibilityLabel = accessibilityLabel
        }
        scroll.maximumZoomScale = maximumZoom
        scroll.onBoundsChange = { [weak coordinator = context.coordinator] in
            coordinator?.layoutImage(resetZoom: false)
        }
        context.coordinator.layoutImage(resetZoom: imageChanged)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image, maximumZoom: maximumZoom)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var image: UIImage
        var maximumZoom: CGFloat
        weak var scrollView: ZoomScrollView?
        weak var imageView: UIImageView?

        init(image: UIImage, maximumZoom: CGFloat) {
            self.image = image
            self.maximumZoom = maximumZoom
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
        }

        func layoutImage(resetZoom: Bool) {
            guard let scrollView, let imageView else { return }
            let size = scrollView.bounds.size
            guard size.width > 0, size.height > 0 else { return }

            let imageSize = image.size
            let widthRatio = size.width / max(imageSize.width, 1)
            let heightRatio = size.height / max(imageSize.height, 1)
            let scale = min(widthRatio, heightRatio)
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

            let currentZoom = scrollView.zoomScale
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            if resetZoom {
                scrollView.zoomScale = 1
            } else {
                scrollView.zoomScale = min(max(currentZoom, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            }
            centerImage()
        }

        func centerImage() {
            guard let scrollView, let imageView else { return }
            let bounds = scrollView.bounds.size
            let frame = imageView.frame
            let insetX = max((bounds.width - frame.width) * 0.5, 0)
            let insetY = max((bounds.height - frame.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let target = min(scrollView.maximumZoomScale, 3)
                let width = scrollView.bounds.width / target
                let height = scrollView.bounds.height / target
                let rect = CGRect(
                    x: point.x - width / 2,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

final class ZoomScrollView: UIScrollView {
    var onBoundsChange: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onBoundsChange?()
        }
    }
}
