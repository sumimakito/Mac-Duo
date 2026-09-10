import AppKit

@main
@MainActor
enum MacDuoMain {
    /// `NSApplication.delegate` is weak, so the delegate needs an owner that
    /// outlives the launch scope.
    private static var delegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
