import AppKit
import Carbon
import Foundation

/// Intercepts global Escape key presses while the depth effect overlay is active,
/// providing an immediate out-of-band escape hatch against UI lockouts.
@MainActor
final class EscapeHatch {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onEscape: () -> Void

    private static let hotKeySignature: OSType = 0x4D44554F // 'MDUO'
    private static let hotKeyID: UInt32 = 1

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    var isEnabled: Bool {
        hotKeyRef != nil
    }

    func enable() {
        guard hotKeyRef == nil else { return }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKey
            )
            if status == noErr,
               hotKey.signature == EscapeHatch.hotKeySignature,
               hotKey.id == EscapeHatch.hotKeyID {
                let unmanaged = Unmanaged<EscapeHatch>.fromOpaque(userData)
                let hatch = unmanaged.takeUnretainedValue()
                DispatchQueue.main.async {
                    hatch.onEscape()
                }
            }
            return noErr
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let target = GetApplicationEventTarget()
        InstallEventHandler(
            target,
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        let regStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            target,
            0,
            &hotKeyRef
        )
        if regStatus != noErr {
            Diagnostics.lid.error("Failed to register Escape emergency hotkey: \(regStatus)")
            if let handlerRef {
                RemoveEventHandler(handlerRef)
                self.handlerRef = nil
            }
        }
    }

    func disable() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
