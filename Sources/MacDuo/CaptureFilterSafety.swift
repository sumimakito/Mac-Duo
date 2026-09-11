import AppKit
import ScreenCaptureKit

/// Resolves the applications a display capture must leave out to avoid
/// feeding Mac Duo's own windows back into its picture.
enum CaptureFilterSafety {
    /// `nil` means the current process is not in the shareable-content list,
    /// so no filter can yet prove that it excludes this instance.
    static func excludedApplications(
        in content: SCShareableContent
    ) -> [SCRunningApplication]? {
        let processID = NSRunningApplication.current.processIdentifier
        guard let currentApplication = content.applications.first(where: {
            $0.processID == processID
        }) else {
            return nil
        }

        // PID confirms this exact process is excluded. When ScreenCaptureKit
        // reports a bundle ID, also exclude other Mac Duo instances: their
        // overlays can feed back just like this one's.
        let bundleID: String? = currentApplication.bundleIdentifier
        guard let bundleID, !bundleID.isEmpty else {
            return [currentApplication]
        }
        return content.applications.filter {
            $0.processID == processID || $0.bundleIdentifier == bundleID
        }
    }
}
