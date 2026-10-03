@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Hosts AVCaptureVideoPreviewLayer. The preview is only a viewfinder: the saved file is
/// the Bayer RAW from the sensor, not this image.
struct CameraPreview: UIViewRepresentable {
    let model: CameraModel

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = model.service.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = { [weak model] point in model?.tap(atLayerPoint: point) }
        view.filterLayer.device = model.service.renderer.metalDevice
        model.attach(previewLayer: view.previewLayer, filterLayer: view.filterLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // FilterRenderer's layer covers the system preview while it draws the viewfinder.
        uiView.filterLayer.isHidden = !model.drawsViewfinder
        uiView.setHold(model.framingHold)
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint) -> Void)?

    /// Filtered viewfinder, drawn by FilterRenderer. Sits above the system preview.
    let filterLayer = CAMetalLayer()
    /// A still of the last frame, shown while the open-gate crop swaps underneath it.
    private let holdLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        filterLayer.pixelFormat = .bgra8Unorm
        filterLayer.framebufferOnly = false          // Core Image writes with compute shaders
        filterLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        filterLayer.isHidden = true
        filterLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(filterLayer)
        holdLayer.contentsGravity = .resizeAspectFill
        holdLayer.masksToBounds = true
        holdLayer.opacity = 0
        layer.addSublayer(holdLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Viewfinder")
        accessibilityHint = String(localized: "Double-tap to focus and meter at the center.")
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filterLayer.frame = bounds
        holdLayer.frame = bounds
        let scale = window?.screen.scale ?? traitCollection.displayScale
        filterLayer.contentsScale = scale
        filterLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }

    /// Covers the viewfinder with `image` at once; on nil, crossfades to the live frames.
    func setHold(_ image: CGImage?) {
        if let image {
            guard holdLayer.contents == nil || holdLayer.opacity == 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            holdLayer.removeAllAnimations()
            holdLayer.contents = image
            holdLayer.opacity = 1
            CATransaction.commit()
        } else if holdLayer.opacity != 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = holdLayer.presentation()?.opacity ?? holdLayer.opacity
            fade.toValue = 0
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [holdLayer] in
                if holdLayer.opacity == 0 { holdLayer.contents = nil }
            }
            holdLayer.opacity = 0
            holdLayer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.location(in: self))
    }

    override func accessibilityActivate() -> Bool {
        onTap?(CGPoint(x: bounds.midX, y: bounds.midY))
        return true
    }
}
