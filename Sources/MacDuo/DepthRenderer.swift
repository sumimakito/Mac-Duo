import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

/// Draws the picture with Metal.
///
/// The picture sits on a black margin in one texture, with a Gaussian pyramid
/// over it. Each frame is one full screen pass.
@MainActor
final class DepthRenderer {

    /// Black margin around the picture, in points. Stays above the largest
    /// blur radius, so the blur reaches real black on every side.
    nonisolated private static let paddingInPoints: CGFloat = 120

    private struct Uniforms {
        var column0: SIMD4<Float>
        var column1: SIMD4<Float>
        var column2: SIMD4<Float>
        var screenAndOrigin: SIMD4<Float>
        var paddedAndBlur: SIMD4<Float>
        var shape: SIMD4<Float>
        var light: SIMD4<Float>
    }

    /// One held picture, built off the main thread and adopted on it.
    struct PreparedPicture {
        let texture: MTLTexture
        let colourSpace: CGColorSpace
        let paddedOrigin: CGPoint
        let paddedSize: CGSize
        let maxLevel: Float
        let pixelScale: CGFloat
        let screenSize: CGSize
    }

    /// Where the next frame goes.
    ///
    /// A layer belongs to one view at a time, so every overlay window needs
    /// its own.
    private(set) var layer = CAMetalLayer()

    nonisolated private let device: MTLDevice
    nonisolated private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var screenSize: CGSize = .zero
    private var pixelScale: CGFloat = 2
    private var paddedOrigin: CGPoint = .zero
    private var paddedSize: CGSize = .zero
    private var maxLevel: Float = 0

    /// The picture a live stream writes into. `makePicture` builds its own
    /// texture instead, so only one of the two is in use at a time.
    private var liveTexture: MTLTexture?
    private var liveSize: CGSize = .zero
    private var liveScale: CGFloat = 0
    private var isLiveSource = false
    /// The newest live frame, waiting for the next drawn frame to take it.
    private var pendingFrame: MTLTexture?
    /// A held picture to start from, waiting for the same moment. A live
    /// frame that arrives first wins, since it is the newer of the two.
    private var pendingSeed: (buffer: MTLBuffer, width: Int, height: Int)?
    private static var hasReportedPyramidFailure = false
    private static var hasReportedPyramidFallback = false
    /// Built once, re-encoded every frame.
    private lazy var livePyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)

    var isReady: Bool { texture != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "depthFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Diagnostics.geometry.error("metal pipeline failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        configure(layer)
    }

    /// A fresh layer for a new overlay window. Later frames go to this one.
    func makeLayer() -> CAMetalLayer {
        let fresh = CAMetalLayer()
        configure(fresh)
        layer = fresh
        return fresh
    }

    private func configure(_ target: CAMetalLayer) {
        target.device = device
        target.pixelFormat = .bgra8Unorm_srgb
        target.framebufferOnly = true
        // An opaque layer covering the screen makes the window server mark
        // every window behind it as hidden, and apps stop drawing. The shader
        // writes alpha 1 everywhere, so blending gives the same picture.
        target.isOpaque = false
        // Waiting for the refresh here blocks the main thread. While a capture
        // stream leaves this app out of its own picture, the window server
        // draws the screen twice, the drawable comes back late, and the wait
        // lands a refresh later: 60 frames per second becomes 32. The display
        // link already paces the drawing.
        target.displaySyncEnabled = false
        target.needsDisplayOnBoundsChange = true
    }

    /// The outcome of building the mip chain under a picture.
    private enum PyramidResult {
        /// The MPS Gaussian pyramid encoded as before.
        case mps
        /// MPS could not run on this GPU; the blit encoder's mipmaps stand in.
        case blitFallback
        /// Neither path worked; the chain above level 0 is unusable.
        case failed
    }

    /// Builds the mip chain in place. MPS is the fast path, but its encode
    /// can fail on some GPUs (reported on Intel, where the frosted glass
    /// came out black while the lid angle kept working). When that happens
    /// the blit encoder's box-filter mipmaps stand in: coarser than a true
    /// Gaussian, but every level the shader samples stays valid instead of
    /// black.
    nonisolated private static func buildPyramid(
        _ pyramid: MPSUnaryImageKernel,
        into texture: inout MTLTexture,
        on commands: MTLCommandBuffer
    ) -> PyramidResult {
        if pyramid.encode(
            commandBuffer: commands,
            inPlaceTexture: &texture,
            fallbackCopyAllocator: nil
        ) {
            return .mps
        }
        guard let blit = commands.makeBlitCommandEncoder() else { return .failed }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        return .blitFallback
    }

    /// Puts the picture on a black margin, uploads it, and builds the pyramid.
    /// Call this off the main thread.
    nonisolated func makePicture(image: CGImage, screenSize: CGSize, pixelScale: CGFloat) -> PreparedPicture? {
        let started = CFAbsoluteTimeGetCurrent()
        let padding = Self.paddingInPoints
        let paddedSize = CGSize(
            width: screenSize.width + 2 * padding,
            height: screenSize.height + 2 * padding
        )
        let width = Int((paddedSize.width * pixelScale).rounded())
        let height = Int((paddedSize.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4

        guard let staging = device.makeBuffer(length: byteCount, options: .storageModeShared) else { return nil }

        let colourSpace: CGColorSpace
        if let space = image.colorSpace, space.model == .rgb {
            colourSpace = space
        } else {
            colourSpace = CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(
            data: staging.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let contextReady = CFAbsoluteTimeGetCurrent()

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let inset = padding * pixelScale
        context.draw(image, in: CGRect(
            x: inset,
            y: inset,
            width: CGFloat(width) - 2 * inset,
            height: CGFloat(height) - 2 * inset
        ))
        let drawn = CFAbsoluteTimeGetCurrent()

        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard var texture = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: width * 4,
            sourceBytesPerImage: byteCount,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        switch Self.buildPyramid(
            MPSImageGaussianPyramid(device: device, centerWeight: 0.375),
            into: &texture,
            on: commands
        ) {
        case .mps:
            break
        case .blitFallback:
            Diagnostics.geometry.notice(
                "MPS pyramid encode failed on this GPU; picture uses blit mipmaps"
            )
        case .failed:
            Diagnostics.geometry.error("could not build the mip chain for the picture")
            return nil
        }
        commands.commit()
        commands.waitUntilCompleted()
        let finished = CFAbsoluteTimeGetCurrent()

        Diagnostics.geometry.notice(
            """
            metal texture \(width)x\(height) px, \(levels) levels: \
            context \((contextReady - started) * 1000, format: .fixed(precision: 1)) ms, \
            draw \((drawn - contextReady) * 1000, format: .fixed(precision: 1)) ms, \
            gpu \((finished - drawn) * 1000, format: .fixed(precision: 1)) ms
            """
        )
        return PreparedPicture(
            texture: texture,
            colourSpace: colourSpace,
            paddedOrigin: CGPoint(x: -padding, y: -padding),
            paddedSize: paddedSize,
            maxLevel: Float(levels - 1),
            pixelScale: pixelScale,
            screenSize: screenSize
        )
    }

    // MARK: - Live source

    /// Prepares the picture for a live stream. The margin is filled with black
    /// once; every frame after that only overwrites the interior. Nothing is
    /// drawn until the first frame lands.
    @discardableResult
    func beginLive(screenSize: CGSize, pixelScale: CGFloat) -> Bool {
        let padding = Self.paddingInPoints
        let padded = CGSize(
            width: screenSize.width + 2 * padding,
            height: screenSize.height + 2 * padding
        )
        let width = Int((padded.width * pixelScale).rounded())
        let height = Int((padded.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return false }

        if liveTexture == nil || liveSize != padded || liveScale != pixelScale {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width,
                height: height,
                mipmapped: true
            )
            // `renderTarget` is only there for the one clear that blacks the
            // margin.
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let fresh = device.makeTexture(descriptor: descriptor) else { return false }
            clearToBlack(fresh)
            liveTexture = fresh
            liveSize = padded
            liveScale = pixelScale
        }

        texture = nil
        isLiveSource = true
        self.screenSize = screenSize
        self.pixelScale = pixelScale
        paddedOrigin = CGPoint(x: -padding, y: -padding)
        paddedSize = padded
        maxLevel = Float(Int(floor(log2(Double(max(width, height))))))
        layer.colorspace = CGColorSpace(name: ScreenStreamer.colourSpaceName)
        layer.drawableSize = CGSize(
            width: screenSize.width * pixelScale,
            height: screenSize.height * pixelScale
        )
        return true
    }

    /// Takes one live frame. The copy and the pyramid are encoded on the same
    /// command buffer as the frame that draws them.
    /// Starts the live picture from one held frame. The stream's first frame
    /// overwrites it.
    @discardableResult
    func seed(image: CGImage) -> Bool {
        guard isLiveSource, liveTexture != nil else { return false }
        let inset = Int((Self.paddingInPoints * pixelScale).rounded())
        let width = Int((screenSize.width * pixelScale).rounded())
        let height = Int((screenSize.height * pixelScale).rounded())
        guard width > 0, height > 0, inset >= 0 else { return false }
        let bytesPerRow = width * 4
        guard let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              // The stream's own space, so the handover does not shift colour.
              let space = CGColorSpace(name: ScreenStreamer.colourSpaceName),
              let context = CGContext(
                data: staging.contents(),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pendingSeed = (staging, width, height)
        texture = liveTexture
        return true
    }

    func absorb(_ frame: MTLTexture) {
        guard isLiveSource, liveTexture != nil else { return }
        pendingFrame = frame
        pendingSeed = nil
        // The texture object is the one the next pass reads, and the copy into
        // it is encoded ahead of that pass.
        texture = liveTexture
    }

    /// Copies the newest frame into the picture and rebuilds the pyramid.
    private func absorbPending(into commands: MTLCommandBuffer) {
        guard var target = liveTexture, pendingFrame != nil || pendingSeed != nil else { return }
        let inset = Int((Self.paddingInPoints * pixelScale).rounded())
        guard let blit = commands.makeBlitCommandEncoder() else { return }
        if let frame = pendingFrame {
            let width = min(frame.width, target.width - 2 * inset)
            let height = min(frame.height, target.height - 2 * inset)
            guard width > 0, height > 0 else { blit.endEncoding(); return }
            blit.copy(
                from: frame,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
            )
        } else if let seed = pendingSeed {
            let width = min(seed.width, target.width - 2 * inset)
            let height = min(seed.height, target.height - 2 * inset)
            guard width > 0, height > 0 else { blit.endEncoding(); return }
            blit.copy(
                from: seed.buffer,
                sourceOffset: 0,
                sourceBytesPerRow: seed.width * 4,
                sourceBytesPerImage: seed.width * 4 * seed.height,
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
            )
        }
        pendingFrame = nil
        pendingSeed = nil
        blit.endEncoding()
        let built = Self.buildPyramid(livePyramid, into: &target, on: commands)
        switch built {
        case .mps:
            break
        case .blitFallback:
            if !Self.hasReportedPyramidFallback {
                Self.hasReportedPyramidFallback = true
                Diagnostics.geometry.notice(
                    "live pyramid: MPS encode failed on this GPU; using blit mipmaps"
                )
            }
        case .failed:
            if !Self.hasReportedPyramidFailure {
                Self.hasReportedPyramidFailure = true
                Diagnostics.geometry.error(
                    "live pyramid failed on both MPS and the blit fallback"
                )
            }
        }
        liveTexture = target
        texture = target
    }

    /// Frees the live picture.
    func discardLive() {
        pendingFrame = nil
        pendingSeed = nil
        if isLiveSource { texture = nil }
        isLiveSource = false
        liveTexture = nil
        liveSize = .zero
        liveScale = 0
    }

    private func clearToBlack(_ target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }

    // MARK: - Still source

    func adopt(_ picture: PreparedPicture) {
        isLiveSource = false
        texture = picture.texture
        // Without a tag the window server treats the drawable as sRGB and
        // converts it to the display space.
        layer.colorspace = picture.colourSpace
        paddedOrigin = picture.paddedOrigin
        paddedSize = picture.paddedSize
        maxLevel = picture.maxLevel
        pixelScale = picture.pixelScale
        screenSize = picture.screenSize
        layer.drawableSize = CGSize(
            width: picture.screenSize.width * picture.pixelScale,
            height: picture.screenSize.height * picture.pixelScale
        )
    }

    func release() {
        texture = nil
    }

    /// - Parameter corners: the picture corners projected onto the screen, in
    ///   points, listed bottom-left, bottom-right, top-right, top-left.
    func render(
        corners: [CGPoint],
        blurStrength: Double,
        dimStrength: Double,
        hingeFloor: Double,
        dimHingeFloor: Double,
        dimReach: Double,
        maxBlurRadius: Double,
        maxDim: Double
    ) {
        guard let commands = queue.makeCommandBuffer() else { return }
        absorbPending(into: commands)
        guard let texture, screenSize.width > 0, screenSize.height > 0,
              let drawable = layer.nextDrawable() else {
            commands.commit()
            return
        }

        let forward = Homography.matrix(
            width: Double(screenSize.width),
            height: Double(screenSize.height),
            to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        )
        let inverse = forward.inverse

        func column(_ index: Int) -> SIMD4<Float> {
            let c = inverse[index]
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
        }
        var uniforms = Uniforms(
            column0: column(0),
            column1: column(1),
            column2: column(2),
            screenAndOrigin: SIMD4(
                Float(screenSize.width), Float(screenSize.height),
                Float(paddedOrigin.x), Float(paddedOrigin.y)
            ),
            paddedAndBlur: SIMD4(
                Float(paddedSize.width), Float(paddedSize.height),
                Float(maxBlurRadius * Double(pixelScale)), Float(blurStrength)
            ),
            shape: SIMD4(Float(hingeFloor), Float(maxDim), Float(pixelScale), maxLevel),
            light: SIMD4(Float(dimHingeFloor), Float(dimStrength), Float(dimReach), 0)
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            commands.commit()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
