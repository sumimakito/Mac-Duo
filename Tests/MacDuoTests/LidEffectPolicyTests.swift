import Testing
@testable import MacDuo

struct LidEffectPolicyTests {
    private let highThreshold = LidEffectPolicy(threshold: 130, hysteresis: 4)

    @Test
    func testOpeningReleasesWithoutReachingHysteresisAngle() {
        #expect(activeEffect(angle: 129, opening: false))
        #expect(!activeEffect(angle: 130, opening: true, minimumDurationElapsed: false))
        #expect(!activeEffect(angle: 131, opening: true))
        #expect(!activeEffect(angle: 133, opening: true))
    }

    @Test
    func testStationaryLidBelowThresholdKeepsActiveEffect() {
        #expect(activeEffect(angle: 129, opening: false))
    }

    @Test
    func testJitterAroundThresholdUsesOrdinaryHysteresis() {
        #expect(activeEffect(angle: 129.8, opening: false))
        #expect(activeEffect(angle: 130.2, opening: false))
        #expect(activeEffect(angle: 129.9, opening: false))
    }

    @Test
    func testOrdinaryConfigurationStillReleasesAtHysteresisAngle() {
        let policy = LidEffectPolicy(threshold: 90, hysteresis: 4)

        #expect(wantsActiveEffect(policy: policy, angle: 93.9, opening: false))
        #expect(!wantsActiveEffect(policy: policy, angle: 94, opening: false))
    }

    @Test
    func testOpeningReversalInvalidatesClosingMemory() {
        var intent = LidMotionIntent()
        intent.update(angularVelocity: -3, at: 10, closingSpeed: 2, openingSpeed: 2)
        #expect(intent.wasClosingRecently(at: 10.1, memoryDuration: 1.5))

        intent.update(angularVelocity: 3, at: 10.2, closingSpeed: 2, openingSpeed: 2)
        #expect(!intent.wasClosingRecently(at: 10.2, memoryDuration: 1.5))

        // A sub-threshold jitter sample must not restore closing intent.
        intent.update(angularVelocity: -0.4, at: 10.3, closingSpeed: 2, openingSpeed: 2)
        #expect(!intent.wasClosingRecently(at: 10.3, memoryDuration: 1.5))
        #expect(
            !highThreshold.wantsEffect(
                isEnabled: true,
                isActive: false,
                angle: 129.9,
                predictedAngle: 129.9,
                hasBeenAboveThreshold: true,
                wasClosingRecently: intent.wasClosingRecently(at: 10.3, memoryDuration: 1.5),
                isClearlyOpening: false,
                minimumDurationElapsed: true
            )
        )
    }

    @Test
    func testRestingBelowThresholdDoesNotActivate() {
        #expect(
            !highThreshold.wantsEffect(
                isEnabled: true,
                isActive: false,
                angle: 129,
                predictedAngle: 129,
                hasBeenAboveThreshold: true,
                wasClosingRecently: false,
                isClearlyOpening: false,
                minimumDurationElapsed: true
            )
        )
    }

    private func activeEffect(
        angle: Double,
        opening: Bool,
        minimumDurationElapsed: Bool = true
    ) -> Bool {
        wantsActiveEffect(
            policy: highThreshold,
            angle: angle,
            opening: opening,
            minimumDurationElapsed: minimumDurationElapsed
        )
    }

    private func wantsActiveEffect(
        policy: LidEffectPolicy,
        angle: Double,
        opening: Bool,
        minimumDurationElapsed: Bool = true
    ) -> Bool {
        policy.wantsEffect(
            isEnabled: true,
            isActive: true,
            angle: angle,
            predictedAngle: angle,
            hasBeenAboveThreshold: true,
            wasClosingRecently: false,
            isClearlyOpening: opening,
            minimumDurationElapsed: minimumDurationElapsed
        )
    }
}
