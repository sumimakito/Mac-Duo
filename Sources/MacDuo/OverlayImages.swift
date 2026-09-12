import AppKit
import Foundation
import ImageIO

/// How user pictures take part in the depth effect.
enum OverlayMode: Int, CaseIterable {
    /// The effect shows the screen only, as before.
    case off = 0
    /// One random picture replaces the screen content.
    case replace = 1
    /// One random picture floats on top of the screen content.
    case onTop = 2
}

/// One picture the user added. The file lives in Application Support under
/// `id`, which is `<UUID>_<original name>`; `name` is the original name.
struct OverlayPicture: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The user's picture library, backed by files in Application Support. The
/// ordered ids live in `Preferences.overlayImageIDs` so the library survives
/// a settings reset.
@MainActor
final class OverlayImageStore: ObservableObject {
    static let shared = OverlayImageStore()

    @Published private(set) var pictures: [OverlayPicture] = []

    private var thumbnails: [String: NSImage] = [:]
    private let preferences = Preferences.shared

    /// Longest side of the image handed to the renderer, in pixels. Full
    /// camera frames would only slow the pyramid build.
    private static let maxPixelSize = 2048
    private static let thumbnailSize: CGFloat = 96

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Mac Duo/Overlays", isDirectory: true)
    }

    private init() {
        reload()
    }

    var isEmpty: Bool { pictures.isEmpty }

    func reload() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let ids = preferences.overlayImageIDs
        var kept: [String] = []
        var found: [OverlayPicture] = []
        for id in ids {
            let url = Self.directory.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            kept.append(id)
            found.append(OverlayPicture(id: id, name: Self.displayName(for: id)))
        }
        if kept != ids { preferences.overlayImageIDs = kept }
        pictures = found
        for key in thumbnails.keys where !kept.contains(key) { thumbnails.removeValue(forKey: key) }
    }

    /// Copies picked files into the library. Returns how many were added.
    @discardableResult
    func add(from urls: [URL]) -> Int {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var ids = preferences.overlayImageIDs
        var added = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty, NSImage(contentsOf: url) != nil else { continue }
            let original = url.deletingPathExtension().lastPathComponent
            let id = UUID().uuidString + "_" + original + "." + ext
            do {
                try FileManager.default.copyItem(at: url, to: Self.directory.appendingPathComponent(id))
            } catch {
                continue
            }
            ids.append(id)
            added += 1
        }
        preferences.overlayImageIDs = ids
        reload()
        return added
    }

    func remove(_ picture: OverlayPicture) {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(picture.id))
        preferences.overlayImageIDs = preferences.overlayImageIDs.filter { $0 != picture.id }
        reload()
    }

    func thumbnail(for picture: OverlayPicture) -> NSImage? {
        if let cached = thumbnails[picture.id] { return cached }
        let url = Self.directory.appendingPathComponent(picture.id)
        guard let image = Self.downscaledImage(at: url, maxPixelSize: Int(Self.thumbnailSize * 2)) else { return nil }
        let thumb = NSImage(cgImage: image, size: NSSize(width: Self.thumbnailSize, height: Self.thumbnailSize))
        thumbnails[picture.id] = thumb
        return thumb
    }

    /// One random picture from the library, downscaled for the GPU.
    func randomCGImage() -> CGImage? {
        let ids = preferences.overlayImageIDs
        guard let id = ids.randomElement() else { return nil }
        return Self.downscaledImage(at: Self.directory.appendingPathComponent(id), maxPixelSize: Self.maxPixelSize)
    }

    // MARK: - Decoding

    private static func downscaledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func displayName(for id: String) -> String {
        guard let dash = id.firstIndex(of: "_") else { return id }
        let rest = String(id[id.index(after: dash)...])
        return URL(fileURLWithPath: rest).deletingPathExtension().lastPathComponent
    }
}
