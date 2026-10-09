import Testing
import simd
@testable import MacDuo

struct PreferencesColorTests {
    @Test
    func testHexColorParsing() {
        // Black
        let black = Preferences.parseHexColor("#000000")
        #expect(black.r == 0.0)
        #expect(black.g == 0.0)
        #expect(black.b == 0.0)
        #expect(black.a == 1.0)

        // White
        let white = Preferences.parseHexColor("#FFFFFF")
        #expect(white.r == 1.0)
        #expect(white.g == 1.0)
        #expect(white.b == 1.0)

        // 3-digit hex (#FFF)
        let shortWhite = Preferences.parseHexColor("#FFF")
        #expect(shortWhite.r == 1.0)
        #expect(shortWhite.g == 1.0)
        #expect(shortWhite.b == 1.0)

        // Hex without #
        let red = Preferences.parseHexColor("FF0000")
        #expect(red.r == 1.0)
        #expect(red.g == 0.0)
        #expect(red.b == 0.0)

        // Custom purple (#8B5CF6)
        let purple = Preferences.parseHexColor("#8B5CF6")
        #expect(abs(purple.r - (139.0 / 255.0)) < 0.01)
        #expect(abs(purple.g - (92.0 / 255.0)) < 0.01)
        #expect(abs(purple.b - (246.0 / 255.0)) < 0.01)
    }

    @Test
    @MainActor
    func testPreferencesBlurColorDefaults() {
        let prefs = Preferences.shared
        #expect(prefs.blurColor.count >= 6)
        let simd = prefs.blurColorSIMD
        #expect(simd.w == 1.0)
    }
}
