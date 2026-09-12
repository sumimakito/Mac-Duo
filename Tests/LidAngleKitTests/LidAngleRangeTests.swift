import XCTest

@testable import LidAngleKit

/// The bug these cover: a start angle of 130 with a hysteresis of 4 waits for
/// 134 degrees, and no MacBook hinge opens that far, so the picture never lets
/// go. Every case below is stated against a hinge that stops somewhere real.
final class LidAngleRangeTests: XCTestCase {

    /// Hinge maxima measured on real machines, plus a narrow one to keep the
    /// arithmetic honest.
    private let hinges: [(name: String, max: Double)] = [
        ("132 degree hinge", 132),
        ("133 degree hinge", 133),
        ("130.9 degree hinge", 130.9),
        ("narrow hinge", 125),
    ]

    private func makeRange(observedMax: Double, hysteresis: Double = 4) -> LidAngleRange {
        LidAngleRange(observedMax: observedMax, hysteresis: hysteresis)
    }

    // MARK: - The trap

    func testHighestOfferedStartAngleStaysReleasableOnEveryHinge() {
        for hinge in hinges {
            let range = makeRange(observedMax: hinge.max)
            let release = range.releaseAngle(startingAt: range.maxThreshold)
            XCTAssertLessThanOrEqual(
                release, hinge.max,
                "\(hinge.name): release at \(release)° needs more than the \(hinge.max)° the hinge has"
            )
        }
    }

    func testStoredStartAngleOf130StaysReleasableOnEveryHinge() {
        // A value written straight to the plist while the app runs skips the
        // clamp, which is how this was first reproduced.
        for hinge in hinges {
            let release = makeRange(observedMax: hinge.max).releaseAngle(startingAt: 130)
            XCTAssertLessThanOrEqual(
                release, hinge.max,
                "\(hinge.name): a stored 130 still asks for \(release)°"
            )
        }
    }

    func testCeilingIsWhatMakesTheTrapReleasable() {
        // Guards the premise as well as the fix. The plain sum is what the app
        // used to wait for, and it does not exist on this hinge.
        let hinge = 132.0
        let range = makeRange(observedMax: hinge)
        XCTAssertGreaterThan(130 + range.hysteresis, hinge, "premise: 134° is not reachable on a 132° hinge")
        XCTAssertTrue(
            range.isReleasable(threshold: 130, reachableMax: hinge),
            "with the ceiling applied, a stored 130 must still be able to let go"
        )
    }

    // MARK: - Ceiling and threshold bounds

    func testReleaseCeilingKeepsClearOfTheHardStop() {
        XCTAssertEqual(makeRange(observedMax: 132).releaseCeiling, 131, accuracy: 0.001)
    }

    func testMaxThresholdLeavesRoomForTheHysteresis() {
        let range = makeRange(observedMax: 132)
        XCTAssertEqual(range.maxThreshold, 127, accuracy: 0.001)
        XCTAssertLessThanOrEqual(range.maxThreshold + range.hysteresis, range.releaseCeiling + 0.001)
    }

    func testUnknownHingeFallsBackToTheAssumedMaximum() {
        let range = makeRange(observedMax: 0)
        XCTAssertEqual(range.knownMax, 130, accuracy: 0.001)
        XCTAssertEqual(range.maxThreshold, 125, accuracy: 0.001)
    }

    func testWiderHingeRaisesTheCeiling() {
        XCTAssertGreaterThan(
            makeRange(observedMax: 136).maxThreshold,
            makeRange(observedMax: 130).maxThreshold
        )
    }

    // MARK: - Clamping stored values

    func testStoredTrapValueIsPulledDown() {
        XCTAssertEqual(makeRange(observedMax: 132).clamped(threshold: 130), 127, accuracy: 0.001)
    }

    func testOrdinaryValuesAreLeftAlone() {
        let range = makeRange(observedMax: 132)
        for threshold in [5.0, 45, 90, 120, 127] {
            XCTAssertEqual(range.clamped(threshold: threshold), threshold, accuracy: 0.001)
        }
    }

    func testValueBelowTheFloorIsRaised() {
        XCTAssertEqual(makeRange(observedMax: 132).clamped(threshold: -20), 5, accuracy: 0.001)
    }

    func testClampingIsIdempotent() {
        let range = makeRange(observedMax: 132)
        let once = range.clamped(threshold: 130)
        XCTAssertEqual(range.clamped(threshold: once), once, accuracy: 0.001)
    }

    // MARK: - Degenerate input

    func testNarrowHingeStillOffersAUsableSpan() {
        // A lid that barely opens, or a first reading taken while nearly shut,
        // must not collapse the control to a single value.
        let range = makeRange(observedMax: 12)
        XCTAssertGreaterThanOrEqual(range.maxThreshold, range.minThreshold + range.minSpan)
    }

    func testZeroHysteresisReleasesAtTheThreshold() {
        let range = makeRange(observedMax: 132, hysteresis: 0)
        XCTAssertEqual(range.releaseAngle(startingAt: 90), 90, accuracy: 0.001)
    }

    func testHysteresisWiderThanTheHingeIsCappedByTheCeiling() {
        let range = makeRange(observedMax: 132, hysteresis: 400)
        XCTAssertEqual(range.releaseAngle(startingAt: 90), range.releaseCeiling, accuracy: 0.001)
        XCTAssertLessThanOrEqual(range.releaseAngle(startingAt: 90), 132)
    }
}
