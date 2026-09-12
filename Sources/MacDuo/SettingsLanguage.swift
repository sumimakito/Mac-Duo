import Foundation

/// The panel language is independent of effect settings and survives Reset.
enum SettingsLanguage: String {
    case english = "en"
    case chinese = "zh-Hans"

    static var preferred: Self {
        Bundle.preferredLocalizations(from: available.map(\.rawValue))
            .first
            .flatMap(Self.init(rawValue:)) ?? .english
    }

    static let available: [SettingsLanguage] = [.english, .chinese]

    func localized(_ key: String) -> String {
        Self.table(for: rawValue)[key] ?? key
    }

    /// `.lproj` directories are not bundles. Wrapping one in `Bundle(path:)`
    /// and calling `localizedString` looks for a nested `*.lproj` inside it,
    /// misses the strings, and returns the English key. `zh-Hans` must also
    /// keep its canonical case — lowercasing it to `zh-hans` fails Bundle's
    /// localization lookup.
    private static func table(for localization: String) -> [String: String] {
        if let cached = cachedTables[localization] { return cached }
        let loaded = loadTable(for: localization)
        cachedTables[localization] = loaded
        return loaded
    }

    private static var cachedTables: [String: [String: String]] = [:]

    // Packaged apps keep resources in Contents/Resources; SwiftPM's generated
    // accessor only searches the app root and the original build directory.
    private static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MacDuo_MacDuo.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    private static func loadTable(for localization: String) -> [String: String] {
        if let path = resources.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: localization
        ), let table = dictionary(at: URL(fileURLWithPath: path)) {
            return table
        }

        let bundleURL = resources.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Resources/\(localization).lproj/Localizable.strings"),
            bundleURL.appendingPathComponent("\(localization).lproj/Localizable.strings"),
            bundleURL.appendingPathComponent("Resources/\(localization).lproj/Localizable.strings"),
        ]
        for url in candidates {
            if let table = dictionary(at: url) { return table }
        }
        return [:]
    }

    private static func dictionary(at url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let table = NSDictionary(contentsOf: url) as? [String: String],
              !table.isEmpty
        else { return nil }
        return table
    }
}
