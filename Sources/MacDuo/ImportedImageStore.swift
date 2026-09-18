import AppKit
import ImageIO

/// One atomic file keeps the original image and its edits consistent across launches.
struct ImportedImageStore {
    struct SavedImage: Codable {
        var png: Data
        var name: String
        var placement: ImagePlacement
        var selected: Bool
    }

    let url: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("to.maki.MacDuo", isDirectory: true)) {
        url = directory.appendingPathComponent("imported-image.plist")
    }

    func save(image: CGImage, name: String, placement: ImagePlacement, selected: Bool) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let record = SavedImage(png: png, name: name, placement: placement, selected: selected)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func load() throws -> (image: CGImage, record: SavedImage)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try PropertyListDecoder().decode(SavedImage.self, from: Data(contentsOf: url))
        let p = record.placement
        guard p.zoom.isFinite, (1...4).contains(p.zoom), p.x.isFinite, (-1...1).contains(p.x),
              p.y.isFinite, (-1...1).contains(p.y),
              let source = CGImageSourceCreateWithData(record.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (image, record)
    }
}
