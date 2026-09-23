import Foundation
import Testing
@testable import MacDuo

struct FrostedGlassTests {

    @Test func flatGlassShowsThePageAsItIs() {
        let brightness = FrostedGlass.brightness(lift: 0, width: 100, height: 60, columns: 4, rows: 3)
        #expect(brightness.allSatisfy { $0 == 1 })
    }

    @Test func liftedGlassLosesLightTowardTheFarEdge() {
        let columns = 8, rows = 6
        let brightness = FrostedGlass.brightness(lift: 40 * .pi / 180, width: 160, height: 100, columns: columns, rows: rows)
        let middle = columns / 2
        #expect(brightness[middle] > brightness[(rows - 1) * columns + middle])
        // Left and right mirror each other.
        #expect(abs(brightness[2 * columns] - brightness[2 * columns + columns - 1]) < 1e-9)
    }

    @Test func moreLiftLosesMoreLight() {
        var previous = 1.0
        for degrees in [10.0, 30, 50, 70] {
            let brightness = FrostedGlass.brightness(
                lift: degrees * Double.pi / 180, width: 160, height: 100, columns: 1, rows: 1
            )[0]
            #expect(brightness < previous)
            previous = brightness
        }
    }
}
