import AppKit

/// Ignore screen notifications that only change brightness or colour, but
/// rebuild capture and windows when a display moves, disconnects or rescales.
struct DisplayLayout: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let isBuiltIn: Bool

    static func selected(from layouts: [Self], includesExternalDisplays: Bool) -> [Self] {
        layouts.filter { $0.isBuiltIn || includesExternalDisplays }
    }

    @MainActor
    static func current(includesExternalDisplays: Bool) -> [Self] {
        let layouts = NSScreen.screens.compactMap { screen -> Self? in
            guard let id = screen.displayID else { return nil }
            return Self(displayID: id, frame: screen.frame, scale: screen.backingScaleFactor,
                        isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
        return selected(from: layouts, includesExternalDisplays: includesExternalDisplays)
    }
}
