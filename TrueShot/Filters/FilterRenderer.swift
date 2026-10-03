@preconcurrency import AVFoundation
import CoreImage
import Metal
import QuartzCore
import Synchronization

/// Renders the filtered viewfinder. Frames arrive from an AVCaptureVideoDataOutput on
/// `videoQueue`, get the LUT applied with Core Image, and are drawn into a CAMetalLayer.
///
/// Only used while a look is selected, or on open-gate formats the system preview stretches;
/// otherwise the app shows the untouched AVCaptureVideoPreviewLayer instead.
final class FilterRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let videoQueue = DispatchQueue(label: "TrueShot.video", qos: .userInteractive)

    private struct State {
        var cube: CubeLUT?
        var intensity: Float = 1
        var grain = GrainSettings()
        /// Draw the viewfinder even with no look (open-gate formats; see CameraModel.drawsViewfinder).
        var passthrough = false
        var layer: LayerBox?
        var snapshot: CIImage?
        /// The last viewfinder image drawn, already framed to the drawable.
        var lastDrawn: CIImage?
        var frameCount = 0
        var meterMode: MeterMode = .system
        var spot = CGPoint(x: 0.5, y: 0.5)
        var onMeter: (@Sendable (MeterStats) -> Void)?
    }

    private let state = Mutex(State())
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        if let commandQueue {
            context = CIContext(mtlCommandQueue: commandQueue, options: [.cacheIntermediates: false])
        } else {
            context = CIContext()
        }
        super.init()
    }

    var metalDevice: MTLDevice? { device }

    func setLayer(_ layer: CAMetalLayer?) {
        let box = layer.map(LayerBox.init)
        state.withLock { $0.layer = box }
    }
    func setFilter(_ cube: CubeLUT?, intensity: Float) {
        state.withLock {
            $0.cube = cube
            $0.intensity = intensity
        }
    }
    func setGrain(_ grain: GrainSettings) { state.withLock { $0.grain = grain } }
    func setPassthrough(_ on: Bool) { state.withLock { $0.passthrough = on } }
    func setMeter(mode: MeterMode, handler: (@Sendable (MeterStats) -> Void)?) {
        state.withLock { $0.meterMode = mode; $0.onMeter = handler }
    }
    /// Spot position in normalized coordinates of the upright, as-displayed frame.
    func setSpot(_ point: CGPoint) { state.withLock { $0.spot = point } }

    /// A small, upright, unfiltered copy of a recent frame, for filter thumbnails.
    func latestSnapshot() -> CIImage? { state.withLock { $0.snapshot } }

    /// The viewfinder as last drawn (look included), for holding over a framing change.
    func lastFrameImage() -> CGImage? {
        guard let image = state.withLock({ $0.lastDrawn }) else { return nil }
        return context.createCGImage(image, from: image.extent, format: .BGRA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// A shared context for thumbnail rendering.
    var ciContext: CIContext { context }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let s = state.withLock { s -> (CubeLUT?, Float, GrainSettings, Bool, CAMetalLayer?, Bool) in
            s.frameCount &+= 1
            return (s.cube, s.intensity, s.grain, s.passthrough, s.layer?.layer, s.frameCount % 15 == 0 || s.snapshot == nil)
        }
        let (cube, intensity, grain, passthrough, layer, takeSnapshot) = s

        // Meter every 6th frame (~5 Hz) on the untouched camera frame, before any look.
        let meter = state.withLock { s -> (MeterMode, CGPoint, (@Sendable (MeterStats) -> Void)?)? in
            s.frameCount % 6 == 0 && s.meterMode != .system ? (s.meterMode, s.spot, s.onMeter) : nil
        }
        if let (mode, spot, handler) = meter, let handler,
           CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
           CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess {
            let stats = CVPixelBufferGetBaseAddress(pixelBuffer).flatMap {
                Meter.measure(bgra: $0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), mode: mode, spot: spot)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            if let stats { handler(stats) }
        }

        // The capture connection rotates and (front camera) mirrors the frames, exactly as for the
        // system preview — it knows each sensor's mounting, which a fixed rule here did not.
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        let image = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))

        if takeSnapshot {
            let scale = 360 / max(image.extent.width, image.extent.height)
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            state.withLock { $0.snapshot = small }
        }

        guard cube != nil || grain.isActive || passthrough, let layer, let commandQueue else { return }
        var look = image
        if let cube { look = LUTLibrary.apply(cube, to: look, intensity: intensity) }
        // A new random offset each frame, so grain moves like film instead of sitting on the lens.
        let seed = CGPoint(x: CGFloat.random(in: 0..<4096).rounded(), y: CGFloat.random(in: 0..<4096).rounded())
        look = Grain.apply(grain, to: look, seed: seed)
        draw(look, in: layer, queue: commandQueue)
    }

    private func draw(_ image: CIImage, in layer: CAMetalLayer, queue: MTLCommandQueue) {
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0, let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }

        // Aspect-fill, centred — the same framing as the AVCaptureVideoPreviewLayer.
        let extent = image.extent
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2
        let dy = (scaled.extent.height - size.height) / 2
        let framed = scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(origin: .zero, size: size))
        state.withLock { $0.lastDrawn = framed }

        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
        destination.isFlipped = true   // Metal textures are top-down (verified against Core Image on macOS).
        destination.colorSpace = layer.colorspace ?? CGColorSpace(name: CGColorSpace.sRGB)
        do {
            _ = try context.startTask(toRender: framed, to: destination)
        } catch {
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// CAMetalLayer is documented as safe to use from a background thread for `nextDrawable()`
/// and `drawableSize` reads, which is all the renderer does with it.
struct LayerBox: @unchecked Sendable {
    let layer: CAMetalLayer
}
