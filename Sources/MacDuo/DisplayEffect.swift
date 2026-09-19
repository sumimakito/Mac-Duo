import AppKit

/// Owns capture and rendering for one display. LidController supplies the
/// same animation angle to every display, but each captures its own contents.
@MainActor
final class DisplayEffect {
    let screen: NSScreen
    private let overlay = DepthOverlay()
    private let snapshotter: ScreenSnapshotter
    private let streamer: ScreenStreamer
    private var pictureTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var isPresenting = false
    private var usesLivePicture = false

    var hostWindow: NSWindow? { overlay.hostWindow }
    var isVisible: Bool { overlay.isVisible }

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.screen = screen
        snapshotter = ScreenSnapshotter(displayID: displayID)
        streamer = ScreenStreamer(displayID: displayID)
    }

    func warmUp() {
        overlay.warmUp()
        guard warmTask == nil else { return }
        warmTask = Task { [weak self] in
            guard let self else { return }
            await snapshotter.warmFilter()
            // Give ScreenCaptureKit time to discover our presence window so
            // all of this app's overlays can be excluded from every capture.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await streamer.warmFilter()
            guard !Task.isCancelled else { return }
            warmTask = nil
        }
    }

    func prewarm(isLive: Bool, shouldCapture: Bool, interval: TimeInterval) {
        guard shouldCapture else {
            snapshotter.stop()
            streamer.stop()
            overlay.discardLive()
            return
        }
        overlay.warmUp()
        if isLive {
            snapshotter.endPrewarm()
            streamer.start()
        } else {
            streamer.stop()
            overlay.discardLive()
            snapshotter.beginPrewarm(interval: interval)
        }
    }

    func present(isLive: Bool, startAngle: Double, tuning: DepthTuning, fadeIn: TimeInterval) {
        isPresenting = true
        snapshotter.endPrewarm()
        if overlay.isVisible {
            if usesLivePicture { streamer.start() }
            return
        }
        guard pictureTask == nil else { return }
        usesLivePicture = false

        if isLive, overlay.showLive(on: screen, startAngle: startAngle, tuning: tuning, fadeIn: fadeIn) {
            usesLivePicture = true
            // A quick close may skip prewarming entirely.
            streamer.start()
            if let frame = streamer.newFrame() {
                overlay.absorb(frame)
                return
            }
            if let image = snapshotter.latestImage {
                overlay.seed(image: image)
                return
            }
        } else {
            streamer.stop()
            if let image = snapshotter.latestImage {
                overlay.show(image: image, on: screen, startAngle: startAngle, tuning: tuning, fadeIn: fadeIn)
                return
            }
        }

        pictureTask = Task { [weak self] in
            guard let self else { return }
            await snapshotter.captureOnce()
            guard !Task.isCancelled, isPresenting else { return }
            pictureTask = nil
            guard let image = snapshotter.latestImage else { return }
            if overlay.isVisible {
                if !overlay.isPictureReady { overlay.seed(image: image) }
            } else {
                overlay.show(image: image, on: screen, startAngle: startAngle, tuning: tuning, fadeIn: fadeIn)
            }
        }
    }

    func update(progress: Double, angle: Double, tuning: DepthTuning) {
        if let frame = streamer.newFrame() { overlay.absorb(frame) }
        overlay.update(progress: progress, currentAngle: angle, tuning: tuning)
    }

    /// Prevent late screenshots from showing a new window during the exit
    /// animation. The live stream stays available until the animation ends.
    func endPresentation() {
        isPresenting = false
        pictureTask?.cancel()
        pictureTask = nil
        snapshotter.stop()
    }

    func dismiss(animated: Bool) {
        endPresentation()
        warmTask?.cancel()
        warmTask = nil
        streamer.stop()
        overlay.dismiss(animated: animated)
        overlay.discardLive()
    }

    /// Also release the invisible presence window when removing a display.
    func dispose() {
        dismiss(animated: false)
        overlay.dispose()
    }
}
