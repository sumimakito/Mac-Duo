import Foundation

/// The panel language is independent of effect settings and survives Reset.
enum SettingsLanguage: String {
    case english = "en"
    case chinese = "zh-Hans"
    case turkish = "tr"

    static var preferred: Self {
        let prefs = Bundle.preferredLocalizations(from: ["en", "zh-Hans", "tr"])
        if let first = prefs.first {
            if first == "zh-Hans" { return .chinese }
            if first == "tr" { return .turkish }
        }
        return .english
    }

    // Packaged apps keep resources in Contents/Resources; SwiftPM's generated
    // accessor only searches the app root and the original build directory.
    private static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MacDuo_MacDuo.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    private var bundle: Bundle {
        guard let path = Self.resources.path(forResource: rawValue.lowercased(), ofType: "lproj"),
              let bundle = Bundle(path: path) else { return Self.resources }
        return bundle
    }

    func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
