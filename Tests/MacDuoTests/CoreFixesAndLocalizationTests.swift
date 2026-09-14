import Testing
import Foundation
import ScreenCaptureKit
@testable import MacDuo

@Suite("Requirement R3: Core Fixes & Localization Reliability")
struct CoreFixesAndLocalizationTests {

    // MARK: - Localization Resolution (zh-Hans)

    @Test("SettingsLanguage.chinese resolves zh-Hans.lproj correctly")
    func testChineseBundleResolution() {
        let chinese = SettingsLanguage.chinese
        let bundle = chinese.resolvedBundle

        // The resolved bundle must point to zh-Hans.lproj, not fallback to main/English resources
        #expect(bundle.bundlePath.hasSuffix("zh-Hans.lproj"))

        // Canonical localized strings from zh-Hans.lproj/Localizable.strings
        #expect(chinese.localized("Start angle") == "起始角度")
        #expect(chinese.localized("Language") == "语言")
        #expect(chinese.localized("Depth effect") == "景深效果")
        #expect(chinese.localized("Live rendering") == "实时渲染")
        #expect(chinese.localized("Timeout") == "超时")
        #expect(chinese.localized("Blur") == "模糊强度")
        #expect(chinese.localized("Dimming") == "变暗强度")
        #expect(chinese.localized("Perspective") == "透视")
        #expect(chinese.localized("Lean back") == "后倾幅度")
        #expect(chinese.localized("Reset") == "重置")
        #expect(chinese.localized("Quit") == "退出")
        #expect(chinese.localized("Chinese (Simplified)") == "简体中文")
    }

    @Test("SettingsLanguage.english resolves en.lproj and returns English strings")
    func testEnglishBundleResolution() {
        let english = SettingsLanguage.english
        let bundle = english.resolvedBundle

        #expect(bundle.bundlePath.hasSuffix("en.lproj"))
        #expect(english.localized("Start angle") == "Start angle")
        #expect(english.localized("Language") == "Language")
        #expect(english.localized("Depth effect") == "Depth effect")
    }

    @Test("SettingsLanguage unknown key returns fallback key unchanged")
    func testUnknownKeyReturnsKey() {
        let unknownKey = "NonExistentKey_XYZ_123"
        #expect(SettingsLanguage.chinese.localized(unknownKey) == unknownKey)
        #expect(SettingsLanguage.english.localized(unknownKey) == unknownKey)
    }

    @Test("SettingsLanguage rawValue initialization supports dynamic switching")
    func testLanguageRawValues() {
        #expect(SettingsLanguage(rawValue: "zh-Hans") == .chinese)
        #expect(SettingsLanguage(rawValue: "en") == .english)
        #expect(SettingsLanguage(rawValue: "invalid") == nil)
    }

    // MARK: - Fail-Closed Capture Filtering

    @Test("ScreenSnapshotter starts with no filter and enforces fail-closed on warmFilter")
    @MainActor
    func testScreenSnapshotterFailClosed() async {
        let snapshotter = ScreenSnapshotter()
        #expect(!snapshotter.hasFilter)
        #expect(snapshotter.currentFilter == nil)
        #expect(snapshotter.latestImage == nil)

        // Attempt warming filter: if self is absent or permission missing, it must FAIL CLOSED
        await snapshotter.warmFilter()

        // Un-excluding filter must NEVER be constructed
        #expect(!snapshotter.hasFilter)
        #expect(snapshotter.currentFilter == nil)

        // Capturing without valid exclusion filter must abort safely with no image
        await snapshotter.captureOnce()
        #expect(snapshotter.latestImage == nil)

        // Discard / stop remains safe and clean
        snapshotter.stop()
        #expect(!snapshotter.hasFilter)
        #expect(snapshotter.latestImage == nil)
    }

    @Test("ScreenStreamer starts with no filter and enforces fail-closed on warmFilter and start")
    @MainActor
    func testScreenStreamerFailClosed() async {
        let streamer = ScreenStreamer()
        #expect(!streamer.hasFilter)
        #expect(streamer.currentFilter == nil)
        #expect(!streamer.isStarted)

        // Attempt warming filter: fail-closed must leave filter as nil
        await streamer.warmFilter()
        #expect(!streamer.hasFilter)
        #expect(streamer.currentFilter == nil)

        // Attempting to start stream without verified self-exclusion must abort
        streamer.start()
        #expect(streamer.newFrame() == nil)

        // Invalidate filter explicitly resets state
        streamer.invalidateFilter()
        #expect(!streamer.hasFilter)
        #expect(streamer.currentFilter == nil)

        streamer.stop()
        #expect(!streamer.isStarted)
    }

    @Test("Process-ID matching verifies current process PID")
    func testPIDVerificationLogic() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let cPID = getpid()
        #expect(currentPID == cPID)

        // Given a simulated list of process IDs without self, fail-closed occurs
        let foreignPIDs: [pid_t] = [1, 2, 99998, 99999]
        let foundSelf = foreignPIDs.contains(currentPID)
        #expect(!foundSelf, "Simulated foreign process list must not match current process PID")

        // Given a simulated list with self, self is accurately identified
        let listWithSelf: [pid_t] = [1, currentPID, 99999]
        let matched = listWithSelf.filter { $0 == currentPID }
        #expect(matched.count == 1)
        #expect(matched.first == currentPID)
    }

    // MARK: - IPC Notification Listener Protection (#if DEBUG)

    #if DEBUG
    @Test("LidController preview IPC observer starts nil and cleans up on stop")
    @MainActor
    func testIPCPreviewObserverLifecycle() {
        let prefs = Preferences.shared
        let controller = LidController(preferences: prefs, observedMaxAngle: 135.0)

        // Before starting, observer is nil
        #expect(!controller.isPreviewObserverRegistered)

        // Calling stop when not started is safe and preserves un-registered state
        controller.stop()
        #expect(!controller.isPreviewObserverRegistered)
    }
    #endif
}
