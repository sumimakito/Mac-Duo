import AppKit
import XCTest
@testable import MacDuo

final class ImportedImageStoreTests: XCTestCase {
    func testOriginalAndEditsSurviveNewStoreInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let c = CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try XCTUnwrap(c.makeImage())
        let placement = ImagePlacement(fill: false, zoom: 2.5, x: -0.4, y: 0.6)
        try ImportedImageStore(directory: directory).save(image: image, name: "portrait.png", placement: placement, selected: true)
        let restored = try XCTUnwrap(ImportedImageStore(directory: directory).load())
        XCTAssertEqual(restored.image.width, 40)
        XCTAssertEqual(restored.image.height, 80)
        XCTAssertEqual(restored.record.name, "portrait.png")
        XCTAssertFalse(restored.record.placement.fill)
        XCTAssertEqual(restored.record.placement.zoom, 2.5)
        XCTAssertEqual(restored.record.placement.x, -0.4)
        XCTAssertEqual(restored.record.placement.y, 0.6)
        XCTAssertTrue(restored.record.selected)
        try ImportedImageStore(directory: directory).save(image: restored.image, name: restored.record.name, placement: restored.record.placement, selected: false)
        let desktop = try XCTUnwrap(ImportedImageStore(directory: directory).load())
        XCTAssertFalse(desktop.record.selected)
        XCTAssertEqual(desktop.record.placement.zoom, 2.5)
    }

    func testMissingAndCorruptRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedImageStore(directory: directory)
        XCTAssertNil(try store.load())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }
}
