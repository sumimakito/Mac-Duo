import AppKit
import XCTest
@testable import MacDuo

final class ImageCropTests: XCTestCase {
    func testAspectRatioAndCoverage() {
        let canvas = CGSize(width: 1600, height: 1000)
        for source in [CGSize(width: 400, height: 1200), CGSize(width: 2400, height: 400), canvas] {
            for fill in [true, false] {
                for zoom: CGFloat in [1, 2, 4] {
                    for offset: CGFloat in [-1, 0, 1] {
                        let p = ImagePlacement(fill: fill, zoom: zoom, x: offset, y: offset)
                        let r = p.rect(source: source, canvas: canvas)
                        XCTAssertEqual(r.width / r.height, source.width / source.height, accuracy: 0.0001)
                        if fill {
                            XCTAssertLessThanOrEqual(r.minX, 0.001)
                            XCTAssertLessThanOrEqual(r.minY, 0.001)
                            XCTAssertGreaterThanOrEqual(r.maxX, 1599.999)
                            XCTAssertGreaterThanOrEqual(r.maxY, 999.999)
                        } else if zoom == 1 {
                            XCTAssertGreaterThanOrEqual(r.minX, -0.001)
                            XCTAssertGreaterThanOrEqual(r.minY, -0.001)
                            XCTAssertLessThanOrEqual(r.maxX, 1600.001)
                            XCTAssertLessThanOrEqual(r.maxY, 1000.001)
                        }
                    }
                }
            }
        }
    }

    private static func image() -> CGImage {
        let c = CGContext(data: nil, width: 40, height: 120, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 40, height: 120))
        return c.makeImage()!
    }

    func testFitRendersBlackBordersAndOpaqueImage() throws {
        let output = try XCTUnwrap(ImagePlacement(fill: false).render(Self.image(), size: CGSize(width: 160, height: 100)))
        XCTAssertEqual(output.width, 160)
        XCTAssertEqual(output.height, 100)
        let c = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8,
                          bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(output, in: CGRect(x: 0, y: 0, width: 160, height: 100))
        let bytes = c.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[50 * 640], 0)
        XCTAssertEqual(bytes[50 * 640 + 3], 255)
        XCTAssertEqual(bytes[50 * 640 + 80 * 4], 255)
    }

    func testEditorCancelAndApply() async {
        await MainActor.run {
            _ = NSApplication.shared
            let editor = ImageCropEditor(image: Self.image(), size: CGSize(width: 160, height: 100), placement: ImagePlacement())
            var applied = 0
            var closed = 0
            editor.completion = { output, _ in
                applied += 1
                XCTAssertEqual(output.width, 160)
            }
            editor.onClose = { closed += 1 }
            editor.cancel()
            XCTAssertEqual(applied, 0)
            XCTAssertEqual(closed, 1)
            editor.zoom.doubleValue = 2
            editor.changed()
            editor.resetImage()
            XCTAssertEqual(editor.placement.zoom, 1)
            editor.apply()
            XCTAssertEqual(applied, 1)
            XCTAssertEqual(closed, 2)
        }
    }
}
