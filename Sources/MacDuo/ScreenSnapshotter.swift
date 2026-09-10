import AppKit
import CoreGraphics
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The built-in display, or `nil` when only external displays are
    /// attached.
    static var builtIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

/// Keeps a recent screenshot of the built-in display ready.
///
/// Building an `SCContentFilter` enumerates every on-screen window, so the
/// filter is cached and rebuilt only when the display changes.
@MainActor
final class ScreenSnapshotter {

    private(set) var latestImage: CGImage?
    private(set) var latestScreen: NSScreen?

    private var filter: SCContentFilter?
    private var filterDisplayID: CGDirectDisplayID?
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private var lastLoggedGeometry: String?

    var isPrewarming: Bool { timer != nil }

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func beginPrewarm(interval: TimeInterval = 0.2) {
        guard timer == nil else { return }
        capture()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endPrewarm() {
        timer?.invalidate()
        timer = nil
    }

    /// Drops the held screenshot.
    func discard() {
        latestImage = nil
        latestScreen = nil
    }

    /// Waits for a screenshot. A pre-warm capture already running counts.
    func captureOnce() async {
        await startCapture().value
    }

    /// Builds the capture filter without taking a screenshot.
    func warmFilter() async {
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { return }
        if filter == nil || filterDisplayID != displayID {
            await rebuildFilter(displayID: displayID)
        }
    }

    private func capture() {
        startCapture()
    }

    @discardableResult
    private func startCapture() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            await self?.performCapture()
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    private func performCapture() async {
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { return }
        if filter == nil || filterDisplayID != displayID {
            await rebuildFilter(displayID: displayID)
        }
        guard let activeFilter = filter else { return }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(activeFilter.contentRect.width * CGFloat(activeFilter.pointPixelScale))
        configuration.height = Int(activeFilter.contentRect.height * CGFloat(activeFilter.pointPixelScale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        do {
            let started = CFAbsoluteTimeGetCurrent()
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: activeFilter,
                configuration: configuration
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            latestImage = image
            latestScreen = screen
            Diagnostics.geometry.debug("captureImage took \(elapsed, format: .fixed(precision: 1)) ms")
            let geometry = String(
                format: "screen %.0fx%.0f pt at (%.0f, %.0f), backingScale %.2f, contentRect %.0fx%.0f, pointPixelScale %.2f, requested %dx%d px, got %dx%d px",
                screen.frame.width, screen.frame.height,
                screen.frame.origin.x, screen.frame.origin.y,
                screen.backingScaleFactor,
                activeFilter.contentRect.width, activeFilter.contentRect.height,
                CGFloat(activeFilter.pointPixelScale),
                configuration.width, configuration.height,
                image.width, image.height
            )
            if geometry != lastLoggedGeometry {
                lastLoggedGeometry = geometry
                Diagnostics.geometry.notice("capture: \(geometry, privacy: .public)")
            }
        } catch {
            filter = nil
            filterDisplayID = nil
        }
    }

    private func rebuildFilter(displayID: CGDirectDisplayID) async {
        do {
            let started = CFAbsoluteTimeGetCurrent()
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            Diagnostics.geometry.notice(
                "SCShareableContent took \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms"
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                filter = nil
                return
            }
            // Exclude ourselves, or a lingering overlay lands in the next snapshot.
            let bundleID = Bundle.main.bundleIdentifier
            let ownApplications = content.applications.filter { $0.bundleIdentifier == bundleID }
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            filterDisplayID = displayID
        } catch {
            filter = nil
            filterDisplayID = nil
        }
    }
}
