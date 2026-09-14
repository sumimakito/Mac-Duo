import Foundation

/// The panel language is independent of effect settings and survives Reset.
enum SettingsLanguage: String {
    case english = "en"
    case chinese = "zh-Hans"

    static var preferred: Self {
        Bundle.preferredLocalizations(from: ["en", "zh-Hans"])
            .first == "zh-Hans" ? .chinese : .english
    }

    // Packaged apps keep resources in Contents/Resources; SwiftPM's generated
    // accessor only searches the app root and the original build directory.
    private static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MacDuo_MacDuo.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    private var bundle: Bundle {
        if let path = Self.resources.path(forResource: rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = Self.resources.path(forResource: rawValue.lowercased(), ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return Self.resources
    }

    var resolvedBundle: Bundle {
        bundle
    }


    func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
