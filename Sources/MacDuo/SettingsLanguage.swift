import Foundation

/// The panel language is independent of effect settings and survives Reset.
enum SettingsLanguage: String, CaseIterable {
    case english = "en"
    case spanish = "es"
    case chinese = "zh-Hans"

    /// The system language, matched against the cases. `preferredLocalizations`
    /// only considers languages the app declares in `CFBundleLocalizations`, so
    /// `Resources/Info.plist` must list every case.
    static var preferred: Self {
        let preferred = Bundle.preferredLocalizations(from: ["en", "es", "zh-Hans"]).first
        if preferred == "es" || preferred?.hasPrefix("es") == true {
            return .spanish
        } else if preferred == "zh-Hans" || preferred?.hasPrefix("zh") == true {
            return .chinese
        } else {
            return .english
        }
    }

    // Packaged apps keep resources in Contents/Resources; SwiftPM's generated
    // accessor only searches the app root and the original build directory.
    private static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MacDuo_MacDuo.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    private var bundle: Bundle {
        Self.lprojBundle(for: rawValue, in: Self.resources) ?? Self.resources
    }

    /// The `.lproj` directory for a language code, as a bundle. SwiftPM writes
    /// the directory as `zh-hans.lproj` with one toolchain and as
    /// `zh-Hans.lproj` with another, and `Bundle` matches the name
    /// case-sensitively, so both spellings are tried.
    static func lprojBundle(for code: String, in resources: Bundle) -> Bundle? {
        for name in [code, code.lowercased()] {
            if let path = resources.path(forResource: name, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
