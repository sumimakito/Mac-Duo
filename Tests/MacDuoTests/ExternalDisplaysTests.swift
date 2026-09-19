import AppKit
import XCTest
@testable import MacDuo

final class ExternalDisplaysTests: XCTestCase {
    private let builtIn = DisplayLayout(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isBuiltIn: true
    )
    private let external = DisplayLayout(
        displayID: 2, frame: CGRect(x: -2560, y: -458, width: 2560, height: 1440), scale: 1, isBuiltIn: false
    )

    func testDisabledExcludesExternalEvenWhenItIsThePrimaryDisplay() {
        XCTAssertEqual(DisplayLayout.selected(from: [external, builtIn], includesExternalDisplays: false), [builtIn])
    }

    func testEnabledPreservesEachDisplaysCoordinatesAndScale() {
        let secondExternal = DisplayLayout(
            displayID: 3, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 2, isBuiltIn: false
        )
        let layouts = [external, builtIn, secondExternal]
        XCTAssertEqual(DisplayLayout.selected(from: layouts, includesExternalDisplays: true), layouts)
    }

    func testExternalOnlyConfigurationRespectsSetting() {
        XCTAssertEqual(DisplayLayout.selected(from: [external], includesExternalDisplays: false), [])
        XCTAssertEqual(DisplayLayout.selected(from: [external], includesExternalDisplays: true), [external])
        XCTAssertEqual(DisplayLayout.selected(from: [], includesExternalDisplays: true), [])
    }

    func testLayoutComparisonDetectsDisconnectMoveAndScaleChange() {
        XCTAssertNotEqual([builtIn, external], [builtIn])
        XCTAssertNotEqual(external, DisplayLayout(
            displayID: 2, frame: external.frame.offsetBy(dx: 100, dy: 0), scale: 1, isBuiltIn: false
        ))
        XCTAssertNotEqual(external, DisplayLayout(
            displayID: 2, frame: external.frame, scale: 2, isBuiltIn: false
        ))
        XCTAssertEqual(external, DisplayLayout(
            displayID: 2, frame: external.frame, scale: 1, isBuiltIn: false
        ))
    }

    @MainActor
    func testSettingDefaultsOffPersistsAndResets() {
        let suite = "MacDuoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.includesExternalDisplays)
        preferences.includesExternalDisplays = true
        XCTAssertTrue(Preferences(defaults: defaults).includesExternalDisplays)
        preferences.resetToDefaults()
        XCTAssertFalse(preferences.includesExternalDisplays)
        XCTAssertFalse(Preferences(defaults: defaults).includesExternalDisplays)
    }
}
