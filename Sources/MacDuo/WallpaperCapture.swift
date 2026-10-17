import AppKit
import ScreenCaptureKit

/// Captures the desktop picture alone, without windows or the menu bar.
///
/// The lock screen shows the desktop picture behind the clock, and it cannot
/// be captured itself, so the lock screen reveal draws this instead. Reading
/// the wallpaper file is not enough: it can live in iCloud Drive and be
/// evicted, or be a dynamic or video wallpaper.
enum WallpaperCapture {

    /// Owner of the windows that draw the desktop picture.
    private static let wallpaperAgent = "com.apple.wallpaper.agent"

    @MainActor
    static func capture(on screen: NSScreen) async -> CGImage? {
        guard let displayID = screen.displayID else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let wallpapers = content.windows.filter { window in
                window.owningApplication?.bundleIdentifier == wallpaperAgent
                    && window.frame.intersects(display.frame)
            }
            guard !wallpapers.isEmpty else {
                Diagnostics.lid.notice("wallpaper: no wallpaper window on the built-in display")
                return nil
            }
            let filter = SCContentFilter(display: display, including: wallpapers)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            Diagnostics.lid.notice("wallpaper: captured \(image.width)x\(image.height)")
            return image
        } catch {
            Diagnostics.lid.notice("wallpaper: capture failed, \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
