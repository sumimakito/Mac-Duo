import AppKit
import Combine
import SwiftUI

/// The menu bar item and the settings popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let preferences: Preferences
    private let controller: LidController
    private var titleSubscription: AnyCancellable?
    private var barWindowMoved: NSObjectProtocol?

    init(controller: LidController, preferences: Preferences) {
        self.controller = controller
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "laptopcomputer",
                accessibilityDescription: "Mac Duo"
            )
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let hostingController = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                controller: controller,
                onQuit: { NSApp.terminate(nil) }
            )
        )
        // Without this the popover keeps its default height and clips the content.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        // Only when the angle or the setting changes, never on a timer.
        titleSubscription = controller.$currentAngle
            .map { $0.rounded() }
            .removeDuplicates()
            .combineLatest(preferences.$showsAngleInMenuBar.removeDuplicates())
            .sink { [weak self] angle, shows in
                self?.setTitle(angle: angle, shows: shows)
            }
        watchBarWindow()
    }

    deinit {
        if let barWindowMoved {
            NotificationCenter.default.removeObserver(barWindowMoved)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate()
            anchor(to: button)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Showing the angle changes the button width, and the status item window
    /// slides along the menu bar about a tenth of a second later. AppKit places
    /// the popover on the width change, before the slide, so it lands a whole
    /// button width away until the window has settled.
    private func watchBarWindow() {
        barWindowMoved = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown,
                      let button = self.statusItem.button,
                      let moved = notification.object as? NSWindow,
                      moved === button.window else { return }
                // Re-showing an animating popover makes it flicker shut.
                let animates = self.popover.animates
                self.popover.animates = false
                self.anchor(to: button)
                self.popover.animates = animates
            }
        }
    }

    /// An empty rectangle means the button's own bounds.
    private func anchor(to button: NSStatusBarButton) {
        popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
    }

    private func setTitle(angle: Double, shows: Bool) {
        guard let button = statusItem.button else { return }
        if shows {
            button.title = String(format: " %.0f°", angle)
        } else if !button.title.isEmpty {
            button.title = ""
        }
    }

    // The panel shows the live angle, which needs the sensor polled.
    func popoverWillShow(_ notification: Notification) {
        controller.isPanelOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        controller.isPanelOpen = false
    }
}
