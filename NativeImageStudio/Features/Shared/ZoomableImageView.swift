import AppKit
import Observation
import SwiftUI

/// Zoom levels and fit math for the full-size image viewer.
public enum ZoomMath {
    public static let minMagnification: CGFloat = 0.05
    public static let maxMagnification: CGFloat = 8
    static let steps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    /// Magnification that shows the whole image in `viewport` (small images are enlarged too).
    public static func fit(image: CGSize, in viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let m = min(viewport.width / image.width, viewport.height / image.height)
        return min(maxMagnification, max(minMagnification, m))
    }

    /// Next preset level above (or below) `current`.
    public static func step(from current: CGFloat, zoomIn: Bool) -> CGFloat {
        let eps: CGFloat = 0.001
        if zoomIn { return steps.first { $0 > current + eps } ?? maxMagnification }
        return steps.last { $0 < current - eps } ?? minMagnification
    }

    /// Double-click: from a fitted view to 100 % (or 2× when the fit already enlarges), otherwise back to fit.
    public static func toggleTarget(current: CGFloat, fitting: Bool) -> CGFloat? {
        guard fitting else { return nil }
        return current < 1 - 0.001 ? 1 : min(maxMagnification, current * 2)
    }
}

/// Drives a `ZoomableImageView` from SwiftUI buttons and shortcuts; mirrors its current zoom.
@MainActor
@Observable
public final class ZoomController {
    public private(set) var magnification: CGFloat = 1
    /// Following the viewport: the image is refitted when the window resizes or the image changes.
    public private(set) var isFitting = true
    @ObservationIgnored weak var scrollView: ZoomScrollView?

    public init() {}

    public func fit() {
        isFitting = true
        scrollView?.fitImage()
        sync()
    }

    public func actualSize() { zoom(to: 1) }
    public func zoomIn() { zoom(to: ZoomMath.step(from: magnification, zoomIn: true)) }
    public func zoomOut() { zoom(to: ZoomMath.step(from: magnification, zoomIn: false)) }

    func zoom(to value: CGFloat, at point: CGPoint? = nil) {
        isFitting = false
        scrollView?.zoom(to: value, at: point)
        sync()
    }

    func userMagnified() {
        isFitting = false
        sync()
    }

    func sync() {
        if let scrollView { magnification = scrollView.magnification }
    }
}

/// Full-resolution image in an `NSScrollView`: trackpad pinch and smart zoom, ⌘-scroll wheel zoom
/// at the cursor, double-click toggles fit / 100 %, panning by scrolling or dragging scrollers.
struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    let controller: ZoomController

    func makeNSView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.controller = controller
        controller.scrollView = view
        view.load(url)
    }
}

final class ZoomScrollView: NSScrollView {
    weak var controller: ZoomController?
    private let imageView = NSImageView()
    private var imageSize: CGSize = .zero
    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        allowsMagnification = true
        minMagnification = ZoomMath.minMagnification
        maxMagnification = ZoomMath.maxMagnification
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        imageView.imageScaling = .scaleAxesIndependently
        documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func load(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // Full size: a thumbnail request larger than the image returns it unscaled, EXIF-oriented.
            let decoded = await Task.detached { ThumbnailCache.decode(url, maxPixel: 16_384).map(SendableImage.init) }.value
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.show(decoded?.cgImage)
        }
    }

    private func show(_ image: CGImage?) {
        imageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        imageView.image = image.map { NSImage(cgImage: $0, size: imageSize) }
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        controller?.fit()
    }

    func fitImage() {
        guard imageSize.width > 0 else { return }
        let m = ZoomMath.fit(image: imageSize, in: contentSize)
        setMagnification(m, centeredAt: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
    }

    /// `point` is in image coordinates; nil keeps the centre of the visible area.
    func zoom(to value: CGFloat, at point: CGPoint?) {
        let visible = contentView.bounds
        setMagnification(value, centeredAt: point ?? CGPoint(x: visible.midX, y: visible.midY))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard controller?.isFitting ?? false else { return }
        fitImage()
        // Called during layout; publish the new zoom afterwards, outside the view update.
        Task { @MainActor [weak self] in self?.controller?.sync() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let controller else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        let point = imageView.convert(event.locationInWindow, from: nil)
        controller.zoom(to: magnification * (1 + delta), at: point)
    }

    @objc private func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
        guard let controller else { return }
        if let target = ZoomMath.toggleTarget(current: magnification, fitting: controller.isFitting) {
            controller.zoom(to: target, at: recognizer.location(in: imageView))
        } else {
            controller.fit()
        }
    }

    @objc private func liveMagnifyEnded() {
        controller?.userMagnified()
    }
}

/// Keeps a document smaller than the viewport centred instead of pinned to the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
