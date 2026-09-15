import Foundation

/// The panel language is independent of effect settings and survives Reset.
enum SettingsLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"
    case chinese = "zh-Hans"

    static var preferred: Self {
        // preferredLocalizations returns one of the identifiers passed in, so an
        // exact match is enough; English leads the list and doubles as the fallback.
        let best = Bundle.preferredLocalizations(from: allCases.map(\.rawValue)).first
        return allCases.first { $0.rawValue == best } ?? .english
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
