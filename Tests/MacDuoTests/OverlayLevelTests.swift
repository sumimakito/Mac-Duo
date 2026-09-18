import AppKit
import XCTest
@testable import MacDuo

final class OverlayLevelTests: XCTestCase {
    func testImportedImageUsesLowerLevelWithoutChangingDesktop() async {
        await MainActor.run {
            let imported = DepthOverlay.overlayLevel(isImportedImage: true).rawValue
            let desktop = DepthOverlay.overlayLevel(isImportedImage: false).rawValue
            XCTAssertEqual(imported, Int(CGWindowLevelForKey(.statusWindow)) + 1)
            XCTAssertLessThan(imported, NSWindow.Level.popUpMenu.rawValue)
            XCTAssertEqual(desktop, Int(CGShieldingWindowLevel()))
            XCTAssertLessThan(imported, desktop)
        }
    }
}
