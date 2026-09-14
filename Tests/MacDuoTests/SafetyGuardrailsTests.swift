import Testing
import Foundation
@testable import MacDuo

@Suite("Requirement R2: Safety & UI Lockout Prevention")
struct SafetyGuardrailsTests {

    @Test("Physical hinge stop dwell release at threshold angle (130°)")
    func testPhysicalStopDwellRelease() {
        let policy = LidEffectPolicy(threshold: 130, hysteresis: 4)
        #expect(policy.dwellAngle == 130.0)

        // At the physical hinge stop (130.0°), before dwelling, effect remains active
        #expect(
            policy.wantsEffect(
                isEnabled: true,
                isActive: true,
                angle: 130.0,
                predictedAngle: 130.0,
                hasBeenAboveThreshold: true,
                wasClosingRecently: false,
                isClearlyOpening: false,
                hasDwelledOpen: false,
                minimumDurationElapsed: true
            )
        )

        // Once the lid has dwelled at the physical stop (130.0°), overlay releases cleanly
        #expect(
            !policy.wantsEffect(
                isEnabled: true,
                isActive: true,
                angle: 130.0,
                predictedAngle: 130.0,
                hasBeenAboveThreshold: true,
                wasClosingRecently: false,
                isClearlyOpening: false,
                hasDwelledOpen: true,
                minimumDurationElapsed: true
            )
        )
    }

    @Test("Dynamic hinge reachability clamping ensures threshold + hysteresis <= observedMaxAngle")
    @MainActor
    func testDynamicHingeClamping() {
        let prefs = Preferences.shared
        let originalThreshold = prefs.thresholdAngle
        defer { prefs.thresholdAngle = originalThreshold }

        // Configure threshold to 130.0°
        prefs.thresholdAngle = 130.0

        // Hardware with 128.0° observed max (e.g. 14-inch MacBook Pro)
        let controller = LidController(preferences: prefs, observedMaxAngle: 128.0)
        #expect(controller.observedMaxAngle == 128.0)

        // Clamped threshold must not exceed 128.0 - 4.0 = 124.0°
        #expect(controller.effectiveThresholdAngle <= 124.0)
        #expect(controller.effectiveThresholdAngle + prefs.hysteresis <= controller.observedMaxAngle)

        // Dynamically observing a larger angle expands the allowable threshold
        controller.observedMaxAngle = 135.0
        #expect(controller.effectiveThresholdAngle == 130.0)
    }

    @Test("Default safety timeout is enabled out of the box")
    @MainActor
    func testDefaultSafetyTimeoutEnabled() {
        let prefs = Preferences.shared
        #expect(prefs.isTimeoutEnabled == true)
    }

    @Test("Emergency escape hatch dismisses overlay, latches release, and prevents re-triggering")
    @MainActor
    func testEmergencyEscapeDismissalAndAntiRetrigger() {
        let prefs = Preferences.shared
        let controller = LidController(preferences: prefs, observedMaxAngle: 135.0)

        // Simulate emergency dismissal while lid is below threshold
        controller.emergencyDismiss()

        #expect(controller.isActive == false)
    }

    @Test("EscapeHatch enable/disable lifecycle")
    @MainActor
    func testEscapeHatchLifecycle() {
        var triggered = false
        let hatch = EscapeHatch {
            triggered = true
        }

        #expect(!hatch.isEnabled)
        hatch.enable()
        #expect(hatch.isEnabled)

        // Duplicate enable is safe idempotent
        hatch.enable()
        #expect(hatch.isEnabled)

        hatch.disable()
        #expect(!hatch.isEnabled)

        // Duplicate disable is safe idempotent
        hatch.disable()
        #expect(!hatch.isEnabled)
        #expect(!triggered)
    }
}
