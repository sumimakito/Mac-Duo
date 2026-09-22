import AppKit
import Metal
import QuartzCore

/// A borderless window above everything, including the menu bar and full
/// screen spaces. It never takes focus and never takes clicks.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The settings that shape one frame.
struct DepthTuning {
    var viewingDistance: Double = 2.7
    var recession: Double = 2
    var blurEvenness: Double = 0.4
    var dimReach: Double = 0.7
    var maxBlurRadius: Double = 55
    var maxDim: Double = 0.4
    /// Degrees of closing after which the far edge reaches `maxBlurRadius`.
    var blurSpan: Double = 60
}

private final class MetalHostView: NSView {
    init(layer metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

/// Owns the overlay window for one run of the effect.
@MainActor
final class DepthOverlay {

    private var window: OverlayWindow?
    /// The window of the previous run while it fades out. AppKit keeps it
    /// alive past the fade, so a new run has to take it down itself.
    private var fadingWindow: OverlayWindow?
    private var presenceWindow: OverlayWindow?
    /// Built once and kept.
    private var renderer: DepthRenderer?
    /// Set while the window server does the blur instead of the renderer.
    private var backdropView: BackdropPortalView?
    private var hasTriedToBuildRenderer = false
    private var buildToken = 0
    private let buildQueue = DispatchQueue(label: "MacDuo.pictureUpload", qos: .userInteractive)

    private var screenSize: CGSize = .zero
    private var startAngle: Double = 90
    private var geometry = DepthGeometry()
    private var gradient = BlurGradient()
    private var tuning = DepthTuning()
    private var fadeIn: TimeInterval = 0.07
    /// Largest fold the window server stretch follows, in radians.
    private static let maxFold = 84.0 * .pi / 180
    private var hasRevealed = false

    var isVisible: Bool { window != nil }
    var isPictureReady: Bool { backdropView != nil || (renderer?.isReady ?? false) }
    var hostWindow: NSWindow? { window }

    @discardableResult
    func warmUp() -> Bool {
        if !hasTriedToBuildRenderer {
            hasTriedToBuildRenderer = true
            renderer = DepthRenderer()
        }
        keepPresence()
        return renderer != nil
    }

    /// A window one point across that shows nothing.
    ///
    /// ScreenCaptureKit only lists an application that owns a window, and the
    /// stream has to name this application to leave the overlay out of its own
    /// picture.
    private func keepPresence() {
        guard presenceWindow == nil else { return }
        let window = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.alphaValue = 0.004
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        presenceWindow = window
    }

    /// Puts up a window for a live stream. It stays transparent until the
    /// first frame is absorbed.
    @discardableResult
    func showLive(
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) -> Bool {
        dismiss(animated: false)
        guard warmUp(), let renderer else { return false }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size

        let pixelScale = Double(screen.backingScaleFactor)
        guard renderer.beginLive(screenSize: screenSize, pixelScale: CGFloat(pixelScale)) else { return false }
        buildToken += 1
        makeWindow(on: screen, pixelScale: pixelScale)
        return window != nil
    }

    /// Hands one live frame to the renderer and reveals the window once the
    /// first one has landed.
    func absorb(_ frame: CapturedFrame) {
        guard window != nil, let renderer else { return }
        renderer.absorb(frame)
        reveal()
    }

    /// Starts a live overlay from one held frame.
    func seed(image: CGImage) {
        guard window != nil, let renderer, renderer.seed(image: image) else { return }
        reveal()
    }

    func discardLive() {
        renderer?.discardLive()
    }

    /// Puts up a window through which the window server leans, blurs and dims
    /// whatever is behind it. Nothing is captured.
    @discardableResult
    func showBackdrop(
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) -> Bool {
        dismiss(animated: false)
        guard BackdropPortalView.isSupported else { return false }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size
        buildToken += 1
        let view = BackdropPortalView(
            frame: NSRect(origin: .zero, size: screenSize),
            scale: screen.backingScaleFactor
        )
        view.autoresizingMask = [.width, .height]
        backdropView = view
        makeWindow(on: screen, contentView: view)
        guard window != nil else {
            backdropView = nil
            return false
        }
        update(progress: 0, currentAngle: startAngle, tuning: tuning)
        reveal()
        return true
    }


    func show(
        image: CGImage,
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) {
        dismiss(animated: false)
        // The screenshot's screen can be stale once the lid shuts into
        // clamshell mode, so no window goes up at its old frame.
        guard let displayID = screen.displayID, displayID == NSScreen.builtIn?.displayID else { return }
        guard warmUp(), let renderer else { return }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size

        let pixelScale = screen.frame.width > 0
            ? Double(image.width) / Double(screen.frame.width)
            : Double(screen.backingScaleFactor)

        makeWindow(on: screen, pixelScale: pixelScale)
        guard let window else { return }

        buildToken += 1
        let token = buildToken
        let size = screenSize
        buildQueue.async { [weak self, weak renderer] in
            guard let renderer else { return }
            let picture = renderer.makePicture(image: image, screenSize: size, pixelScale: CGFloat(pixelScale))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.buildToken == token, self.window === window,
                          let picture else { return }
                    renderer.adopt(picture)
                    self.update(progress: 0, currentAngle: self.startAngle, tuning: self.tuning)
                    self.reveal()
                }
            }
        }
    }

    private func makeWindow(on screen: NSScreen, pixelScale: Double) {
        guard let renderer else { return }
        let view = MetalHostView(layer: renderer.makeLayer(), scale: CGFloat(pixelScale))
        view.frame = NSRect(origin: .zero, size: screenSize)
        view.autoresizingMask = [.width, .height]
        makeWindow(on: screen, contentView: view)
    }

    private func makeWindow(on screen: NSScreen, contentView view: NSView) {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        hasRevealed = false
        self.window = window
    }

    /// Fades the window in once, and only once the picture has something to
    /// draw.
    private func reveal() {
        guard let window, !hasRevealed, isPictureReady else { return }
        hasRevealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func update(progress: Double, currentAngle: Double, tuning: DepthTuning) {
        self.tuning = tuning
        // The screen stays where the glass started and the glass, frosted,
        // turns away from it by the whole of the lid's travel. The gap between
        // them sets the blur, whatever the picture's lean.
        let separation = geometry.separation(
            startAngle: startAngle,
            currentAngle: currentAngle,
            recession: 1
        )
        // How far the top edge sits behind the glass once the lid has closed
        // by `blurSpan`. A gap that size blurs by the full radius.
        let fullGap = Double(screenSize.height) * sin(geometry.separation(
            startAngle: tuning.blurSpan,
            currentAngle: 0,
            recession: 1
        ))
        if let backdropView {
            // The glass folds away from the flat screen by the lid's travel,
            // so the screen is drawn out by 1 / cos of it. Past this the
            // stretch runs away as the lid shuts.
            let fold = min(separation, Self.maxFold)
            let farGap = fullGap > 1
                ? min(Double(screenSize.height) * sin(separation) / fullGap, DepthRenderer.maxGapFraction)
                : 0
            let hingeBlur = tuning.blurEvenness * gradient.blurStrength(progress: progress)
            let farBlur = hingeBlur + (1 - tuning.blurEvenness) * farGap
            backdropView.apply(
                stretch: 1 / cos(fold),
                blurRadius: farBlur * tuning.maxBlurRadius,
                hingeBlur: hingeBlur * tuning.maxBlurRadius,
                dimStrength: gradient.dimStrength(progress: progress),
                dimHingeFloor: gradient.dimHingeFloor,
                dimReach: tuning.dimReach,
                maxDim: tuning.maxDim
            )
            return
        }
        guard let renderer, renderer.isReady else { return }
        renderer.render(
            separation: separation,
            fullBlurGap: fullGap,
            corners: geometry.corners(
                startAngle: startAngle,
                currentAngle: currentAngle,
                viewingDistanceRatio: tuning.viewingDistance,
                recession: tuning.recession,
                screenSize: screenSize
            ),
            blurStrength: gradient.blurStrength(progress: progress),
            dimStrength: gradient.dimStrength(progress: progress),
            hingeFloor: tuning.blurEvenness,
            dimHingeFloor: gradient.dimHingeFloor,
            dimReach: tuning.dimReach,
            maxBlurRadius: tuning.maxBlurRadius,
            maxDim: tuning.maxDim
        )
    }

    func dismiss(animated: Bool, duration: TimeInterval = 0.22) {
        closeFadingWindow()
        guard let window else { return }
        self.window = nil
        buildToken += 1
        renderer?.release()
        backdropView = nil

        guard animated else {
            window.orderOut(nil)
            window.close()
            return
        }

        fadingWindow = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.fadingWindow === window { self.fadingWindow = nil }
                window.orderOut(nil)
                window.close()
            }
        }
    }

    /// Takes down a window that is still fading.
    private func closeFadingWindow() {
        guard let fadingWindow else { return }
        self.fadingWindow = nil
        fadingWindow.orderOut(nil)
        fadingWindow.close()
    }
}
