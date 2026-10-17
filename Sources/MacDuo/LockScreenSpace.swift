import AppKit

/// A window server space that draws above the lock screen.
///
/// Ordinary windows stay hidden behind the lock screen, so the reveal that
/// plays when the lid opens onto it needs a space at a higher absolute level.
/// This goes through private SkyLight calls, looked up at runtime so a macOS
/// that drops them only loses the lock screen reveal.
///
/// Adapted from SkyLightWindow by Lakr Aream (MIT):
/// https://github.com/Lakr233/SkyLightWindow
@MainActor
final class LockScreenSpace {

    static let shared = LockScreenSpace()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`, one step above
    /// the lock screen itself at 300.
    private static let absoluteLevel: Int32 = 400

    private let connection: Int32
    private let space: Int32
    private let addWindows: SpaceAddWindowsAndRemoveFromSpaces?

    var isAvailable: Bool { addWindows != nil && space != 0 }

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW),
              let mainConnection = dlsym(handle, "SLSMainConnectionID"),
              let create = dlsym(handle, "SLSSpaceCreate"),
              let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let show = dlsym(handle, "SLSShowSpaces"),
              let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            Diagnostics.lid.notice("lock screen space: SkyLight calls not found")
            connection = 0
            space = 0
            addWindows = nil
            return
        }
        connection = unsafeBitCast(mainConnection, to: MainConnectionID.self)()
        space = unsafeBitCast(create, to: SpaceCreate.self)(connection, 1, 0)
        _ = unsafeBitCast(setLevel, to: SpaceSetAbsoluteLevel.self)(connection, space, Self.absoluteLevel)
        _ = unsafeBitCast(show, to: ShowSpaces.self)(connection, [space] as CFArray)
        addWindows = unsafeBitCast(add, to: SpaceAddWindowsAndRemoveFromSpaces.self)
        Diagnostics.lid.notice("lock screen space: created \(self.space)")
    }

    /// Moves an ordered-in window into the space.
    func adopt(_ window: NSWindow) {
        guard let addWindows, space != 0 else { return }
        window.canBecomeVisibleWithoutLogin = true
        let result = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        Diagnostics.lid.notice("lock screen space: adopted window \(window.windowNumber), result \(result)")
    }
}
