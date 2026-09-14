import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: LidController

    /// Empty means following the system language.
    @AppStorage("settingsLanguage") private var language = ""

    private var selectedLanguage: SettingsLanguage {
        SettingsLanguage(rawValue: language) ?? .preferred
    }

    private func localized(_ key: String) -> String {
        selectedLanguage.localized(key)
    }

    private var _launchesAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    private var launchesAtLogin: Bool {
        get { _launchesAtLogin.wrappedValue }
        nonmutating set { _launchesAtLogin.wrappedValue = newValue }
    }

    private var hasScreenPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private var _settingsOpenFailed = State(initialValue: false)
    private var settingsOpenFailed: Bool {
        get { _settingsOpenFailed.wrappedValue }
        nonmutating set { _settingsOpenFailed.wrappedValue = newValue }
    }

    var onQuit: () -> Void

    private static let width: CGFloat = 300
    private static let inset: CGFloat = 14
    private static let bodyHeight: CGFloat = 400
    private static let authorURL = URL(string: "https://github.com/sumimakito")!
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.inset)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            if controller.isSensorAvailable {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switches
                        if !hasScreenPermission {
                            permissionNotice
                        }
                        startGroup
                        lookGroup
                        perspectiveGroup
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 10)
                }
                .frame(height: Self.bodyHeight)
            } else {
                unavailableNotice
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 12)
            }
            Divider()
            appGroup
                .padding(.horizontal, Self.inset)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mac Duo").font(.title2.weight(.semibold))
            Spacer()
            Text(String(format: "%.1f°", controller.currentAngle))
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(localized("Lid angle"))
        }
    }

    private var unavailableNotice: some View {
        Text(localized("This Mac has no lid angle sensor. Only some MacBook models have one."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 4) {
            toggleRow(
                localized("Depth effect"),
                isOn: $preferences.isEnabled,
                help: localized("Leans the screen away as the lid closes.")
            )
            toggleRow(
                localized("Live rendering"),
                isOn: $preferences.isLivePicture,
                help: localized("Off holds the frame from when the effect started.")
            )
            .disabled(!preferences.isEnabled)
        }
    }

    private var startGroup: some View {
        group(localized("Start")) {
            toggleRow(
                localized("Timeout"),
                isOn: $preferences.isTimeoutEnabled,
                help: localized("Ends the effect once the angle stops changing.")
            )
            slider(
                localized("Start angle"), value: $preferences.thresholdAngle, in: 5...130, format: "%.0f°",
                help: localized("The effect starts at this angle.")
            )
            slider(
                localized("Full effect after"), value: $preferences.blurSpan, in: 5...60, format: "%.0f°",
                help: localized("Degrees of further closing to reach full strength.")
            )
        }
    }

    private var lookGroup: some View {
        group(localized("Look")) {
            slider(
                localized("Blur"), value: $preferences.maxBlurRadius, in: 10...160, format: "%.0f pt",
                help: localized("Blur radius at the far edge.")
            )
            slider(
                localized("Blur spread"), value: $preferences.blurEvenness, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("0 blurs the far edge only, 100 the whole picture.")
            )
            blurColorRow
            slider(
                localized("Dimming"), value: $preferences.maxDim, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("How dark the far edge goes.")
            )
            slider(
                localized("Dimming spread"), value: $preferences.dimReach, in: 0.2...1, format: "%.0f%%", scale: 100,
                help: localized("Everything above this height goes fully dark.")
            )
        }
    }

    private var perspectiveGroup: some View {
        group(localized("Perspective")) {
            slider(
                localized("Lean back"), value: $preferences.recession, in: 0...3, format: "%.1f×",
                help: localized("Degrees of lean per degree of closing. 1 holds it still.")
            )
            slider(
                localized("Perspective"), value: perspective, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("0 keeps the sides parallel, 100 converges sharply.")
            )
        }
    }

    private var appGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localized("Language"))
                Spacer()
                Picker("", selection: $language) {
                    Text(localized("System")).tag("")
                    Text(verbatim: "English").tag(SettingsLanguage.english.rawValue)
                    Text(localized("Spanish")).tag(SettingsLanguage.spanish.rawValue)
                    Text(localized("Chinese (Simplified)")).tag(SettingsLanguage.chinese.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(localized("Language"))
            }
            toggleRow(localized("Show angle in menu bar"), isOn: $preferences.showsAngleInMenuBar, help: nil)
            toggleRow(localized("Launch at login"), isOn: _launchesAtLogin.projectedValue, help: nil)
                .onChange(of: launchesAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }
            HStack {
                Button(localized("Reset")) { preferences.resetToDefaults() }
                Spacer()
                Button(localized("Quit"), action: onQuit)
            }
            .controlSize(.small)
            .padding(.top, 2)
            HStack(spacing: 0) {
                Text(localized("Made by ")).foregroundStyle(.secondary)
                Link("Makito", destination: Self.authorURL)
                    .pointingHand()
                Spacer()
                Text("© 2026 Makito").foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(.top, 2)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(title)
            }
            description(help)
        }
    }

    @ViewBuilder
    private func description(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct ColorPreset: Identifiable {
        let id: String
        let name: String
        let hex: String
        let color: Color
    }

    private var colorPresets: [ColorPreset] {
        [
            ColorPreset(id: "black", name: localized("Black"), hex: "#000000", color: .black),
            ColorPreset(id: "white", name: localized("White"), hex: "#FFFFFF", color: .white),
            ColorPreset(id: "slate", name: localized("Slate"), hex: "#334155", color: Color(red: 51/255, green: 65/255, blue: 85/255)),
            ColorPreset(id: "navy", name: localized("Navy"), hex: "#0F172A", color: Color(red: 15/255, green: 23/255, blue: 42/255)),
            ColorPreset(id: "purple", name: localized("Purple"), hex: "#8B5CF6", color: Color(red: 139/255, green: 92/255, blue: 246/255)),
            ColorPreset(id: "cyan", name: localized("Cyan"), hex: "#06B6D4", color: Color(red: 6/255, green: 182/255, blue: 212/255)),
            ColorPreset(id: "orange", name: localized("Orange"), hex: "#F97316", color: Color(red: 249/255, green: 115/255, blue: 22/255)),
            ColorPreset(id: "rose", name: localized("Rose"), hex: "#F43F5E", color: Color(red: 244/255, green: 63/255, blue: 94/255)),
            ColorPreset(id: "emerald", name: localized("Emerald"), hex: "#10B981", color: Color(red: 16/255, green: 185/255, blue: 129/255)),
        ]
    }

    private var blurColorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localized("Blur color"))
                Spacer()
                ColorPicker("", selection: blurColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .scaleEffect(0.85)
                    .frame(width: 24, height: 24)
                    .help(localized("Custom color"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(colorPresets) { preset in
                        colorPresetButton(preset)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 1)
            }
        }
    }

    private func colorPresetButton(_ preset: ColorPreset) -> some View {
        let isSelected = preferences.blurColor.uppercased() == preset.hex.uppercased()
        return Button {
            preferences.blurColor = preset.hex
        } label: {
            ZStack {
                Circle()
                    .fill(preset.color)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                    )
                if isSelected {
                    Circle()
                        .strokeBorder(preset.hex == "#FFFFFF" ? Color.black : Color.white, lineWidth: 2)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .pointingHand()
    }

    private var blurColorBinding: Binding<Color> {
        Binding(
            get: {
                let (r, g, b, a) = Preferences.parseHexColor(preferences.blurColor)
                return Color(red: r, green: g, blue: b, opacity: a)
            },
            set: { newColor in
                if let nsColor = NSColor(newColor).usingColorSpace(.sRGB) {
                    let r = Int(round(max(0, min(1, nsColor.redComponent)) * 255))
                    let g = Int(round(max(0, min(1, nsColor.greenComponent)) * 255))
                    let b = Int(round(max(0, min(1, nsColor.blueComponent)) * 255))
                    preferences.blurColor = String(format: "#%02X%02X%02X", r, g, b)
                }
            }
        )
    }

    private var perspective: Binding<Double> {
        Binding(
            get: { (Preferences.farthestEye - preferences.viewingDistance) / Preferences.eyeRange },
            set: { preferences.viewingDistance = Preferences.farthestEye - $0 * Preferences.eyeRange }
        )
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Screen Recording permission is required to show the depth effect."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(localized("Open System Settings")) {
                    openScreenRecordingSettings()
                }
                .controlSize(.small)
            }
            if settingsOpenFailed {
                Text(localized("Could not open System Settings. Open it manually and enable screen recording for Mac Duo under Privacy & Security."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        settingsOpenFailed = false
        Task { @MainActor in
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open(Self.screenRecordingSettingsURL, configuration: configuration)
            } catch {
                settingsOpenFailed = true
            }
        }
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .disabled(!preferences.isEnabled)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        scale: Double = 1,
        help: String? = nil
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(reading)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
            description(help)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private extension View {
    func pointingHand() -> some View {
        modifier(PointingHand())
    }
}

private struct PointingHand: ViewModifier {
    private var _pushed = State(initialValue: false)
    private var pushed: Bool {
        get { _pushed.wrappedValue }
        nonmutating set { _pushed.wrappedValue = newValue }
    }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}
