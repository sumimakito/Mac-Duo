import AppKit
import Metal
import QuartzCore
import simd

/// Draws the picture with Metal.
///
/// The picture is read straight from where it lives: a live frame from its
/// capture surface, a still from one upload. A half size blur pyramid sits
/// beside it, and only as many levels as the current blur needs are built.
/// A frame whose inputs match the last one drawn is skipped, so a lid held
/// still over an unchanging screen costs nothing.
@MainActor
final class DepthRenderer {

    private struct Uniforms: Equatable {
        var column0: SIMD4<Float>
        var column1: SIMD4<Float>
        var column2: SIMD4<Float>
        var screen: SIMD4<Float>
        var blur: SIMD4<Float>
        var light: SIMD4<Float>
        var gap: SIMD4<Float>
    }

    /// One held picture, built off the main thread and adopted on it.
    struct PreparedPicture {
        let texture: MTLTexture
        let colourSpace: CGColorSpace
        let pixelScale: CGFloat
        let screenSize: CGSize
    }

    /// The blur setting is a radius; the shader wants a Gaussian sigma. This
    /// keeps the look the setting had with the earlier mip blur.
    nonisolated private static let sigmaPerRadius: Double = 0.7
    /// Beyond this many levels a level is a handful of texels and adds nothing.
    nonisolated private static let maxPyramidLevels = 10
    nonisolated private static let pictureFormat: MTLPixelFormat = .bgra8Unorm_srgb
    /// The blur keeps growing past the full effect angle, up to this multiple.
    static let maxGapFraction: Double = 1.5

    /// Where the next frame goes.
    ///
    /// A layer belongs to one view at a time, so every overlay window needs
    /// its own.
    private(set) var layer = CAMetalLayer()

    nonisolated private let device: MTLDevice
    nonisolated private let queue: MTLCommandQueue
    private let compositePipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState

    /// The full size picture.
    private var base: MTLTexture?
    /// Keeps the capture surface behind `base` out of the stream's pool.
    private var baseFrame: CapturedFrame?
    private var pyramid: MTLTexture?
    /// One single level view per pyramid level, as render targets and sources.
    private var pyramidLevels: [MTLTexture] = []
    /// Pyramid levels that hold the current picture.
    private var builtLevels = 0
    /// Bumped whenever `base` changes content.
    private var generation: UInt64 = 0
    private var lastDrawn: (uniforms: Uniforms, generation: UInt64)?

    private var screenSize: CGSize = .zero
    private var pixelScale: CGFloat = 2
    private var isLiveSource = false
    /// A held picture to start a live run from, uploaded on the next frame.
    /// A live frame that arrives first wins, since it is the newer of the two.
    private var pendingSeed: (buffer: MTLBuffer, width: Int, height: Int)?
    private var seedTexture: MTLTexture?

    var isReady: Bool { base != nil || pendingSeed != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
            let composite = MTLRenderPipelineDescriptor()
            composite.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            composite.fragmentFunction = library.makeFunction(name: "compositeFragment")
            // Not sRGB: the shader encodes and dithers itself.
            composite.colorAttachments[0].pixelFormat = .bgra8Unorm
            compositePipeline = try device.makeRenderPipelineState(descriptor: composite)

            let downsample = MTLRenderPipelineDescriptor()
            downsample.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            downsample.fragmentFunction = library.makeFunction(name: "downsampleFragment")
            downsample.colorAttachments[0].pixelFormat = Self.pictureFormat
            downsamplePipeline = try device.makeRenderPipelineState(descriptor: downsample)
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
        lastDrawn = nil
        return fresh
    }

    private func configure(_ target: CAMetalLayer) {
        target.device = device
        target.pixelFormat = .bgra8Unorm
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
        // Two in flight is enough when frames are only drawn on change.
        target.maximumDrawableCount = 2
    }

    /// Uploads a still picture. Call this off the main thread.
    nonisolated func makePicture(image: CGImage, screenSize: CGSize, pixelScale: CGFloat) -> PreparedPicture? {
        let started = CFAbsoluteTimeGetCurrent()
        let width = Int((screenSize.width * pixelScale).rounded())
        let height = Int((screenSize.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4

        let colourSpace: CGColorSpace
        if let space = image.colorSpace, space.model == .rgb {
            colourSpace = space
        } else {
            colourSpace = CGColorSpaceCreateDeviceRGB()
        }
        guard let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let context = CGContext(
                data: staging.contents(),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colourSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let drawn = CFAbsoluteTimeGetCurrent()

        guard let texture = makePictureTexture(width: width, height: height),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow * height,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        Diagnostics.geometry.notice(
            """
            metal texture \(width)x\(height) px: \
            draw \((drawn - started) * 1000, format: .fixed(precision: 1)) ms, \
            upload \((CFAbsoluteTimeGetCurrent() - drawn) * 1000, format: .fixed(precision: 1)) ms
            """
        )
        return PreparedPicture(
            texture: texture,
            colourSpace: colourSpace,
            pixelScale: pixelScale,
            screenSize: screenSize
        )
    }

    nonisolated private func makePictureTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pictureFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Live source

    /// Prepares for a live stream. Nothing is drawn until the first frame or
    /// seed lands.
    @discardableResult
    func beginLive(screenSize: CGSize, pixelScale: CGFloat) -> Bool {
        guard screenSize.width > 0, screenSize.height > 0 else { return false }
        setBase(nil, frame: nil)
        isLiveSource = true
        self.screenSize = screenSize
        self.pixelScale = pixelScale
        layer.colorspace = CGColorSpace(name: ScreenStreamer.colourSpaceName)
        layer.drawableSize = CGSize(
            width: screenSize.width * pixelScale,
            height: screenSize.height * pixelScale
        )
        return true
    }

    /// Starts the live picture from one held frame. The stream's first frame
    /// replaces it.
    @discardableResult
    func seed(image: CGImage) -> Bool {
        guard isLiveSource else { return false }
        let width = Int((screenSize.width * pixelScale).rounded())
        let height = Int((screenSize.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return false }
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
        return true
    }

    /// Takes one live frame. Nothing is copied: the next pass reads the
    /// capture surface itself.
    func absorb(_ frame: CapturedFrame) {
        guard isLiveSource else { return }
        pendingSeed = nil
        setBase(frame.texture, frame: frame)
    }

    /// Frees the live picture.
    func discardLive() {
        pendingSeed = nil
        if isLiveSource { setBase(nil, frame: nil) }
        isLiveSource = false
        seedTexture = nil
        pyramid = nil
        pyramidLevels = []
    }

    private func uploadPendingSeed(into commands: MTLCommandBuffer) {
        guard let seed = pendingSeed else { return }
        pendingSeed = nil
        if seedTexture?.width != seed.width || seedTexture?.height != seed.height {
            seedTexture = makePictureTexture(width: seed.width, height: seed.height)
        }
        guard let target = seedTexture, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: seed.buffer,
            sourceOffset: 0,
            sourceBytesPerRow: seed.width * 4,
            sourceBytesPerImage: seed.width * 4 * seed.height,
            sourceSize: MTLSize(width: seed.width, height: seed.height, depth: 1),
            to: target,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        setBase(target, frame: nil)
    }

    private func setBase(_ texture: MTLTexture?, frame: CapturedFrame?) {
        base = texture
        baseFrame = frame
        builtLevels = 0
        generation &+= 1
    }

    // MARK: - Still source

    func adopt(_ picture: PreparedPicture) {
        isLiveSource = false
        pendingSeed = nil
        setBase(picture.texture, frame: nil)
        // Without a tag the window server treats the drawable as sRGB and
        // converts it to the display space.
        layer.colorspace = picture.colourSpace
        pixelScale = picture.pixelScale
        screenSize = picture.screenSize
        layer.drawableSize = CGSize(
            width: picture.screenSize.width * picture.pixelScale,
            height: picture.screenSize.height * picture.pixelScale
        )
    }

    func release() {
        pendingSeed = nil
        setBase(nil, frame: nil)
        pyramid = nil
        pyramidLevels = []
        lastDrawn = nil
    }

    // MARK: - Pyramid

    /// Levels needed for a blur of `sigma` pixels, plus one to blend into.
    private func levelsNeeded(sigma: Double) -> Int {
        guard sigma > DepthShaders.sigmaPerLevel else { return 0 }
        let lod = log2(sigma / DepthShaders.sigmaPerLevel)
        return min(Int(lod.rounded(.up)) + 1, pyramidLevels.isEmpty ? Self.maxPyramidLevels : pyramidLevels.count)
    }

    private func ensurePyramid(width: Int, height: Int) {
        let levelWidth = max(width / 2, 1)
        let levelHeight = max(height / 2, 1)
        if let pyramid, pyramid.width == levelWidth, pyramid.height == levelHeight { return }
        let fullChain = Int(floor(log2(Double(max(levelWidth, levelHeight))))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pictureFormat,
            width: levelWidth,
            height: levelHeight,
            mipmapped: true
        )
        descriptor.mipmapLevelCount = min(fullChain, Self.maxPyramidLevels)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let fresh = device.makeTexture(descriptor: descriptor) else {
            pyramid = nil
            pyramidLevels = []
            return
        }
        pyramid = fresh
        pyramidLevels = (0..<descriptor.mipmapLevelCount).compactMap { level in
            fresh.makeTextureView(
                pixelFormat: Self.pictureFormat,
                textureType: .type2D,
                levels: level..<(level + 1),
                slices: 0..<1
            )
        }
        builtLevels = 0
    }

    /// Builds pyramid levels `builtLevels..<count` from the ones before.
    private func buildPyramid(upTo count: Int, from source: MTLTexture, into commands: MTLCommandBuffer) {
        guard count > builtLevels else { return }
        for level in builtLevels..<min(count, pyramidLevels.count) {
            let target = pyramidLevels[level]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            var size = SIMD2<Float>(Float(target.width), Float(target.height))
            encoder.setRenderPipelineState(downsamplePipeline)
            encoder.setFragmentBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentTexture(level == 0 ? source : pyramidLevels[level - 1], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            builtLevels = level + 1
        }
    }

    // MARK: - Drawing

    /// The picture stays where the glass started while the glass turns away
    /// from it. Each point is blurred by how far the picture sits behind the
    /// glass there, the way a picture behind frosted glass softens with
    /// distance: sharp along the hinge, softest at the far edge.
    ///
    /// - Parameters:
    ///   - separation: the angle between the glass and the picture, radians.
    ///   - fullBlurGap: the gap, in points, that blurs by `maxBlurRadius`.
    ///   - corners: the picture corners projected onto the screen, in points,
    ///     listed bottom-left, bottom-right, top-right, top-left.
    func render(
        separation: Double,
        fullBlurGap: Double,
        corners: [CGPoint],
        blurStrength: Double,
        dimStrength: Double,
        hingeFloor: Double,
        dimHingeFloor: Double,
        dimReach: Double,
        maxBlurRadius: Double,
        maxDim: Double
    ) {
        guard isReady, screenSize.width > 0, screenSize.height > 0 else { return }

        let maxSigma = maxBlurRadius * Double(pixelScale) * Self.sigmaPerRadius
        let topGapFraction = fullBlurGap > 1
            ? min(Double(screenSize.height) * sin(separation) / fullBlurGap, Self.maxGapFraction)
            : 0
        let widestBlur = hingeFloor * blurStrength + (1 - hingeFloor) * topGapFraction
        // The footprint of a shrunk picture wants a level or so beyond that.
        let wanted = levelsNeeded(sigma: max(widestBlur * maxSigma, 1.5))
        let seedPending = pendingSeed != nil
        let levelsAfter = seedPending ? wanted : max(builtLevels, wanted)
        let generationAfter = seedPending ? generation &+ 1 : generation

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
            screen: SIMD4(
                Float(screenSize.width), Float(screenSize.height),
                Float(pixelScale), Float(levelsAfter)
            ),
            blur: SIMD4(Float(maxSigma), Float(blurStrength), Float(hingeFloor), 0),
            light: SIMD4(Float(dimHingeFloor), Float(dimStrength), Float(dimReach), Float(maxDim)),
            gap: SIMD4(
                Float(sin(separation)),
                Float(max(fullBlurGap, 1)),
                Float(Self.maxGapFraction),
                0
            )
        )
        if let lastDrawn, lastDrawn.uniforms == uniforms, lastDrawn.generation == generationAfter {
            return
        }

        guard let commands = queue.makeCommandBuffer() else { return }
        uploadPendingSeed(into: commands)
        guard let base else {
            commands.commit()
            return
        }
        if wanted > builtLevels {
            ensurePyramid(width: base.width, height: base.height)
            buildPyramid(upTo: wanted, from: base, into: commands)
        }
        uniforms.screen.w = Float(builtLevels)

        guard let drawable = layer.nextDrawable() else {
            commands.commit()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            commands.commit()
            return
        }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(base, index: 0)
        encoder.setFragmentTexture(pyramid ?? base, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        // The pool must not hand the capture surface back to the stream while
        // this pass still reads it.
        let held = baseFrame
        commands.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        commands.commit()
        lastDrawn = (uniforms, generation)
    }
}
