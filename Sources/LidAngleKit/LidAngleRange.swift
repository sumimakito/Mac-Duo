/// The band of lid angles the depth effect may work in on this Mac.
///
/// Hinges differ by model and nothing in the sensor reports the range, so the
/// widest angle seen is remembered and every bound is derived from it. The
/// property that matters: a release is only ever asked for at an angle the lid
/// has already been observed to reach. A start angle sitting near the hinge
/// stop therefore cannot leave the picture up for good.
public struct LidAngleRange: Equatable, Sendable {

    /// Widest angle the sensor has reported, or zero before the first reading.
    public var observedMax: Double

    /// Degrees above the start angle at which an active effect lets go. Keeps
    /// the picture from flickering around the boundary.
    public var hysteresis: Double

    /// Degrees kept clear of `observedMax`, so letting go never asks for the
    /// lid to be held against its hard stop.
    public var reachMargin: Double

    /// Stands in for the hinge until the first reading arrives.
    public var assumedMax: Double

    /// Lowest start angle offered.
    public var minThreshold: Double

    /// Narrowest span the start angle is allowed to offer, so a low
    /// `observedMax` cannot collapse the control to a single value.
    public var minSpan: Double

    public init(
        observedMax: Double,
        hysteresis: Double,
        reachMargin: Double = 1,
        assumedMax: Double = 130,
        minThreshold: Double = 5,
        minSpan: Double = 5
    ) {
        self.observedMax = observedMax
        self.hysteresis = hysteresis
        self.reachMargin = reachMargin
        self.assumedMax = assumedMax
        self.minThreshold = minThreshold
        self.minSpan = minSpan
    }

    /// The hinge maximum in use: measured once known, assumed before that.
    public var knownMax: Double {
        observedMax > 0 ? observedMax : assumedMax
    }

    /// Widest angle a release may be asked for. Anything past it is a release
    /// the hinge cannot perform.
    public var releaseCeiling: Double {
        max(minThreshold, knownMax - reachMargin)
    }

    /// Highest start angle worth offering, so the release that follows from it
    /// still lands inside `releaseCeiling`.
    public var maxThreshold: Double {
        max(minThreshold + minSpan, releaseCeiling - hysteresis)
    }

    /// The angle an active effect lets go at, with the hysteresis held inside
    /// the reachable range.
    public func releaseAngle(startingAt threshold: Double) -> Double {
        min(threshold + hysteresis, releaseCeiling)
    }

    /// Pulls a start angle into the range the hinge can leave. Values from an
    /// earlier version, or written straight to the plist, can sit above it.
    public func clamped(threshold: Double) -> Double {
        min(max(threshold, minThreshold), maxThreshold)
    }

    /// Whether a lid at `angle` can still let the effect go. False means the
    /// configuration traps the picture on screen.
    public func isReleasable(threshold: Double, reachableMax: Double) -> Bool {
        releaseAngle(startingAt: threshold) <= reachableMax
    }
}
