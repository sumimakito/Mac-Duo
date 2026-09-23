import AppKit
import QuartzCore

/// The fold done entirely by the window server, on whatever is behind the
/// overlay. Nothing is captured, so it needs no Screen Recording permission,
/// runs no capture stream and draws nothing on the GPU from this process.
///
/// It draws `FrostedGlass`: the screen stays where the glass started, like a
/// page, and the glass is a frosted sheet lifted off it about the hinge. Each
/// point is blurred by its height above the page, and darkened by the share
/// of its light that misses the page.
///
/// The window server's own variable blur switches between shrunk copies of
/// the screen as the radius grows, which shows as horizontal lines across a
/// blur that rises up the screen. So the blur is a stack of bands instead,
/// each a `CABackdropLayer` with a uniform `gaussianBlur` at the radius the
/// optics give its height, each fading in over the one below. The bands share
/// one capture of the screen, so none of them blurs another's output.
///
/// `CABackdropLayer` and `CAFilter` are private Core Animation classes, looked
/// up at run time; `isSupported` is false when either is missing.
@MainActor
final class BackdropPortalView: NSView {

    /// Gaussian sigma of the window server's `gaussianBlur`, per unit of its
    /// `inputRadius`, measured on a one point line.
    private static let sigmaPerRadius = 1.3
    /// A Gaussian holds half its light within this many sigmas.
    private static let halfLightSigmas = 1.1774
    /// Band tops as a share of the height are `(i / count)²`: close together
    /// by the hinge, where the blur grows fastest relative to itself.
    private static let bandCount = 8
    /// How far past a band's visible part it captures, in blur radii, so its
    /// edges blur real content rather than nothing.
    private static let marginRadii = 3.0
    private static let groupName = "MacDuo.fold"
    /// Stops in each band's fade. A plain linear fade leaves a visible kink
    /// where it starts and ends.
    private static let fadeStops = 9
    /// The darkening grid. It varies slowly, and the layer smooths it.
    private static let shadeColumns = 40
    private static let shadeRows = 26

    static var isSupported: Bool {
        NSClassFromString("CABackdropLayer") != nil && NSClassFromString("CAFilter") != nil
    }

    private var bands: [CALayer] = []
    private let shade = CALayer()
    private var lastState: [Double] = []
    /// Brightness grids by whole degree of lift, for the current size.
    private var brightnessCache: [Int: [Double]] = [:]
    private var cachedSize: CGSize = .zero

    init(frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        let root = CALayer()
        root.contentsScale = scale
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        if Self.isSupported {
            // Lowest band first: each fades in over the ones below it.
            for _ in 0..<Self.bandCount {
                guard let band = Self.makeBand() else { break }
                band.contentsScale = scale
                band.isHidden = true
                root.addSublayer(band)
                bands.append(band)
            }
        }
        shade.anchorPoint = .zero
        shade.contentsGravity = .resize
        shade.magnificationFilter = .linear
        shade.isHidden = true
        root.addSublayer(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        shade.frame = bounds
        CATransaction.commit()
        lastState = []
    }

    private static func makeBand() -> CALayer? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let blur = makeFilter("gaussianBlur") else { return nil }
        blur.setValue("blur", forKey: "name")
        blur.setValue(0.0, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        // A wide blur of a dark screen is a smooth near-black gradient, which
        // 8 bits draw as contour bands. Dithered, it reads as one gradient.
        blur.setValue(true, forKey: "inputDither")

        let band = backdropClass.init()
        band.anchorPoint = .zero
        // Samples what other windows draw, not only this window's content.
        band.setValue(true, forKey: "windowServerAware")
        // One capture for every band, taken before any of them draws.
        band.setValue(groupName, forKey: "groupName")
        band.filters = [blur]

        let fade = CAGradientLayer()
        fade.anchorPoint = .zero
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        band.mask = fade
        return band
    }

    private static func makeFilter(_ type: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector) else { return nil }
        return filterClass.perform(selector, with: type)?.takeUnretainedValue() as? NSObject
    }

    /// - Parameters:
    ///   - lift: the angle between the glass and the screen it left, radians.
    ///   - frost: how diffuse the glass is. One is a Lambertian sheet, like
    ///     tracing paper; less is clearer.
    ///   - darkness: how much of the lost light shows as dark. One is all.
    func apply(lift: Double, frost: Double, darkness: Double) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let lift = min(max(lift, 0), .pi / 2)
        let state = [lift, frost, darkness]
        guard state != lastState else { return }
        lastState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let isFlat = lift < 1e-3
        let height = Double(size.height)
        // Blur radius per point of height above the hinge.
        let radiusPerHeight = FrostedGlass.halfLightRadiusPerHeight * max(frost, 0) * sin(lift)
            / Self.halfLightSigmas / Self.sigmaPerRadius
        let count = bands.count
        func top(_ index: Int) -> Double {
            guard index > 0 else { return 0 }
            let share = Double(min(index, count)) / Double(count)
            return height * share * share
        }
        for (index, band) in bands.enumerated() {
            // Band `index` fades in from `start` to `full`, and the band above
            // covers it from `next` up.
            let start = top(index), full = top(index + 1), next = top(index + 2)
            let radius = radiusPerHeight * full
            band.isHidden = isFlat || radius < 0.3
            guard !band.isHidden else { continue }
            let margin = Self.marginRadii * radius
            let low = max(start - margin, 0)
            let high = min(max(next, full) + margin, height)
            band.frame = CGRect(x: 0, y: low, width: size.width, height: high - low)
            band.setValue(radius, forKeyPath: "filters.blur.inputRadius")
            if let fade = band.mask as? CAGradientLayer {
                fade.frame = band.bounds
                Self.shapeFade(fade, from: (start - low) / (high - low), to: (full - low) / (high - low))
            }
        }

        shade.isHidden = isFlat || darkness <= 0
        if !shade.isHidden {
            shade.contents = shadeImage(lift: lift, darkness: darkness, size: size)
        }
    }

    /// Clear below `from`, opaque above `to`, and a smoothstep between: no
    /// kink where the fade starts or ends.
    private static func shapeFade(_ fade: CAGradientLayer, from: Double, to: Double) {
        var locations: [NSNumber] = [0]
        var colours: [CGColor] = [CGColor(gray: 0, alpha: 0)]
        for stop in 0..<fadeStops {
            let t = Double(stop) / Double(fadeStops - 1)
            let eased = t * t * (3 - 2 * t)
            locations.append(NSNumber(value: min(max(from + (to - from) * t, 0), 1)))
            colours.append(CGColor(gray: 0, alpha: eased))
        }
        locations.append(1)
        colours.append(CGColor(gray: 0, alpha: 1))
        fade.locations = locations
        fade.colors = colours
    }

    // MARK: - Darkening

    private func shadeImage(lift: Double, darkness: Double, size: CGSize) -> CGImage? {
        if size != cachedSize {
            brightnessCache = [:]
            cachedSize = size
        }
        let degree = Int((lift * 180 / .pi).rounded())
        let brightness: [Double]
        if let cached = brightnessCache[degree] {
            brightness = cached
        } else {
            brightness = FrostedGlass.brightness(
                lift: Double(degree) * .pi / 180,
                width: Double(size.width),
                height: Double(size.height),
                columns: Self.shadeColumns,
                rows: Self.shadeRows
            )
            brightnessCache[degree] = brightness
        }
        let columns = Self.shadeColumns, rows = Self.shadeRows
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            // Image rows run from the top; brightness rows from the hinge.
            let imageRow = rows - 1 - row
            for column in 0..<columns {
                // The light lost is a share of linear light. The window server
                // blends the black over encoded values, so the share goes in
                // through the transfer curve, or the glass comes out far too dark.
                let kept = pow(max(brightness[row * columns + column], 0), 1 / 2.2)
                let alpha = min(max(darkness * (1 - kept), 0), 1)
                pixels[(imageRow * columns + column) * 4 + 3] = UInt8((alpha * 255).rounded())
            }
        }
        return pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}
