import Foundation

struct LidMotionIntent {
    private(set) var lastMovedDownTime: TimeInterval = -Double.greatestFiniteMagnitude

    mutating func update(
        angularVelocity: Double,
        at now: TimeInterval,
        closingSpeed: Double,
        openingSpeed: Double
    ) {
        if angularVelocity >= openingSpeed {
            // Opening is an intentional reversal, so an earlier close must not
            // be reused to start the effect again near the threshold.
            lastMovedDownTime = -Double.greatestFiniteMagnitude
        } else if angularVelocity <= -closingSpeed {
            lastMovedDownTime = now
        }
    }

    func wasClosingRecently(at now: TimeInterval, memoryDuration: TimeInterval) -> Bool {
        now - lastMovedDownTime < memoryDuration
    }

    mutating func reset() {
        lastMovedDownTime = -Double.greatestFiniteMagnitude
    }
}

/// How long the lid has stayed opened back above the start angle.
struct LidOpenDwell {
    private(set) var since: TimeInterval?

    mutating func update(angle: Double, at now: TimeInterval, dwellAngle: Double) {
        if angle >= dwellAngle {
            if since == nil { since = now }
        } else {
            since = nil
        }
    }

    func hasDwelled(at now: TimeInterval, duration: TimeInterval) -> Bool {
        guard let since else { return false }
        return now - since >= duration
    }

    mutating func reset() {
        since = nil
    }
}

struct LidEffectPolicy {
    let threshold: Double
    let hysteresis: Double

    /// A lid held at or above this angle has been opened again, even when
    /// threshold + hysteresis is past what the hinge can reach.
    var dwellAngle: Double { threshold + min(hysteresis, 1) }

    func wantsEffect(
        isEnabled: Bool,
        isActive: Bool,
        angle: Double,
        predictedAngle: Double,
        hasBeenAboveThreshold: Bool,
        wasClosingRecently: Bool,
        isClearlyOpening: Bool,
        hasDwelledOpen: Bool,
        minimumDurationElapsed: Bool
    ) -> Bool {
        guard isEnabled else { return false }

        if isActive {
            // Deliberately opening back across the configured start angle is
            // sufficient to recover even when threshold + hysteresis cannot
            // be reached by the hardware.
            if isClearlyOpening, angle >= threshold { return false }

            // An opening slower than that still ends with the lid held above
            // the start angle, which releases it too.
            if hasDwelledOpen { return false }

            // Keep the ordinary release hysteresis for stationary readings and
            // sensor jitter around the start angle.
            guard minimumDurationElapsed else { return true }
            return angle < threshold + hysteresis
        }

        // A resting or opening lid below the threshold must not start the
        // effect, including while an older closing observation is remembered.
        return hasBeenAboveThreshold
            && wasClosingRecently
            && !isClearlyOpening
            && predictedAngle <= threshold
    }
}
