import Combine
import Foundation
import LidAngleKit

/// User settings, backed by `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let isTimeoutEnabled = "isTimeoutEnabled"
        static let thresholdAngle = "thresholdAngle"
        static let blurSpan = "blurSpan"
        static let maxBlurRadius = "maxBlurRadius"
        static let maxDim = "maxDim"
        static let viewingDistance = "viewingDistance"
        static let recession = "recession"
        static let blurEvenness = "blurEvenness"
        static let dimReach = "dimReach"
        static let showsAngleInMenuBar = "showsAngleInMenuBar"
        static let isLivePicture = "isLivePicture"
        static let observedMaxAngle = "observedMaxAngle"

        // `observedMaxAngle` is left out on purpose. It measures the hinge
        // rather than stating a preference, and forgetting it would hand back
        // a start angle the lid cannot open past.
        static let all = [
            isEnabled, isTimeoutEnabled, thresholdAngle, blurSpan, maxBlurRadius,
            maxDim, viewingDistance, recession, blurEvenness, dimReach,
            showsAngleInMenuBar, isLivePicture,
        ]
    }

    private static let factory: [String: Any] = [
        Key.isEnabled: true,
        // On by default. It is the only release the lid can reach without
        // opening all the way, and a user who needs it is by then looking at
        // a picture that hides the panel holding the switch.
        Key.isTimeoutEnabled: true,
        Key.thresholdAngle: 90.0,
        Key.blurSpan: 60.0,
        Key.maxBlurRadius: 135.0,
        Key.maxDim: 1.0,
        Key.viewingDistance: 6.0,
        Key.recession: 1.0,
        Key.blurEvenness: 0.0,
        Key.dimReach: 0.5,
        Key.showsAngleInMenuBar: false,
        Key.isLivePicture: true,
        Key.observedMaxAngle: 0.0,
    ]

    /// Master switch for the depth effect.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// Ends the effect early if the angle holds still while below the
    /// threshold, instead of waiting for the lid to open back past it.
    @Published var isTimeoutEnabled: Bool {
        didSet { defaults.set(isTimeoutEnabled, forKey: Key.isTimeoutEnabled) }
    }

    /// Closing past this angle starts the depth effect. Degrees.
    @Published var thresholdAngle: Double {
        didSet { defaults.set(thresholdAngle, forKey: Key.thresholdAngle) }
    }

    /// How many degrees below the threshold the blur takes to reach maximum.
    @Published var blurSpan: Double {
        didSet { defaults.set(blurSpan, forKey: Key.blurSpan) }
    }

    /// Gaussian blur radius at full effect, in points.
    @Published var maxBlurRadius: Double {
        didSet { defaults.set(maxBlurRadius, forKey: Key.maxBlurRadius) }
    }

    /// Black overlay opacity where the blur is at full strength, 0...1.
    @Published var maxDim: Double {
        didSet { defaults.set(maxDim, forKey: Key.maxDim) }
    }

    /// Distance from the eye to the middle of the screen, as a multiple of
    /// the screen height.
    @Published var viewingDistance: Double {
        didSet { defaults.set(viewingDistance, forKey: Key.viewingDistance) }
    }

    /// Degrees the picture turns away from the glass for each degree the lid
    /// closes. One holds the picture still in the room.
    @Published var recession: Double {
        didSet { defaults.set(recession, forKey: Key.recession) }
    }

    /// Blur at the hinge edge as a fraction of the blur at the far edge. One
    /// blurs the whole picture by the same amount.
    @Published var blurEvenness: Double {
        didSet { defaults.set(blurEvenness, forKey: Key.blurEvenness) }
    }

    /// Height at which the dimming reaches full strength, as a fraction of
    /// the screen height.
    @Published var dimReach: Double {
        didSet { defaults.set(dimReach, forKey: Key.dimReach) }
    }

    /// Draw the live angle next to the menu bar icon.
    @Published var showsAngleInMenuBar: Bool {
        didSet { defaults.set(showsAngleInMenuBar, forKey: Key.showsAngleInMenuBar) }
    }

    /// Keep the picture under the effect updating, instead of holding the one
    /// frame that was on screen at the trigger angle.
    @Published var isLivePicture: Bool {
        didSet { defaults.set(isLivePicture, forKey: Key.isLivePicture) }
    }

    /// Widest angle the sensor has reported on this Mac, or zero before the
    /// first reading. Hinges differ by model, and nothing in the sensor
    /// reports the range, so it is learned and remembered.
    @Published private(set) var observedMaxAngle: Double {
        didSet { defaults.set(observedMaxAngle, forKey: Key.observedMaxAngle) }
    }

    /// Eye distance in screen heights, at the two ends of the perspective
    /// slider. The panel offers the strength, which runs the other way.
    static let farthestEye: Double = 6
    static let nearestEye: Double = 1
    static let eyeRange: Double = farthestEye - nearestEye

    /// Highest angle above the threshold at which the pre-warm may run.
    let prewarmCeiling: Double = 70

    /// Closing speed in degrees per second that starts the pre-warm.
    let closingSpeed: Double = 8

    /// How long the pre-warm runs after the lid stops moving.
    let prewarmLinger: TimeInterval = 2

    /// Seconds between pre-warm screenshots.
    let prewarmInterval: TimeInterval = 0.25

    /// Degrees above the threshold before the overlay is released.
    let hysteresis: Double = 4

    /// Degrees kept clear of the widest angle seen, so letting go never asks
    /// the lid to be pressed against its hard stop.
    let reachMargin: Double = 1

    /// A reading wider than this is sensor noise, not a wider hinge.
    let plausibleMaxAngle: Double = 150

    /// Lowest start angle the panel offers.
    static let minThresholdAngle: Double = 5

    /// Stands in for the hinge before the first reading arrives. The sensor
    /// header puts a MacBook at roughly this much.
    static let assumedMaxAngle: Double = 130

    /// The reachable angle band, rebuilt from what the sensor has reported.
    var angleRange: LidAngleRange {
        LidAngleRange(
            observedMax: observedMaxAngle,
            hysteresis: hysteresis,
            reachMargin: reachMargin,
            assumedMax: Self.assumedMaxAngle,
            minThreshold: Self.minThresholdAngle
        )
    }

    /// Widest angle an active effect may be asked to release at. Anything
    /// beyond it is a release the hinge cannot perform.
    var releaseCeiling: Double { angleRange.releaseCeiling }

    /// Highest start angle the panel offers, so the release that follows from
    /// it stays inside `releaseCeiling`.
    var maxThresholdAngle: Double { angleRange.maxThreshold }

    /// Widens the known hinge range. Fed every sensor reading.
    func noteObserved(angle: Double) {
        guard angle > observedMaxAngle, angle <= plausibleMaxAngle else { return }
        observedMaxAngle = angle
    }

    /// Pulls a stored start angle back into the range the hinge can leave.
    /// Values from an earlier version, or written straight to the plist, can
    /// sit above it.
    func clampThresholdAngle() {
        let bounded = angleRange.clamped(threshold: thresholdAngle)
        guard bounded != thresholdAngle else { return }
        thresholdAngle = bounded
    }

    /// Settings from earlier versions, removed at launch.
    private static let retired = [
        "blurFrontWidth", "maxTilt", "tiltDegrees", "tiltRatio", "dimEvenness",
    ]

    private let defaults = UserDefaults.standard

    // No inline values on purpose. Swift skips property observers for the
    // assignment that initialises a property.
    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.factory)
        for key in Self.retired { defaults.removeObject(forKey: key) }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
        observedMaxAngle = defaults.double(forKey: Key.observedMaxAngle)
        clampThresholdAngle()
    }

    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
        clampThresholdAngle()
    }
}
