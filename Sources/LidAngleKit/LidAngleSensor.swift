import Foundation
import IOKit
import IOKit.hid

/// Reads the lid hinge angle from the MacBook orientation sensor.
///
/// The sensor is an Apple HID device on usage page `0x20`, usage `0x8A`, that
/// macOS marks as built-in. No product ID is required, and an external display
/// with the same usage is left out. Two reports carry the angle, both through
/// `kIOHIDReportTypeFeature`:
///
/// - Report 1: 3 bytes `[0x01, lo, hi]`, whole degrees, 0...360.
/// - Report 7: 5 bytes `[0x07, b0, b1, b2, b3]`, little-endian hundredths of a
///   degree. Not every model declares it, so report 1 is the fallback.
///
/// The value refreshes about every 100 ms and needs no permission.
public final class LidAngleSensor {

    /// Which report the sensor answers with, decided once at open time.
    public enum Resolution {
        /// Report 7, 0.01 degree steps.
        case hundredthsOfADegree
        /// Report 1, 1 degree steps.
        case wholeDegrees

        public var reportID: Int {
            switch self {
            case .hundredthsOfADegree: return 7
            case .wholeDegrees: return 1
            }
        }

        public var describedName: String {
            switch self {
            case .hundredthsOfADegree: return "report 7 (0.01°)"
            case .wholeDegrees: return "report 1 (1°)"
            }
        }
    }

    /// What the last call to `angle()` saw. A failed read returns `nil` and
    /// leaves the reason here.
    public struct ReadTrace {
        /// The result of `IOHIDDeviceGetReport`.
        public var status: IOReturn = kIOReturnSuccess
        /// Bytes the device wrote.
        public var length: Int = 0
        public var bytes: [UInt8] = []
        /// The decoded value when it fell outside 0...360.
        public var rejectedDegrees: Double?
    }

    public private(set) var lastRead = ReadTrace()
    public private(set) var resolution: Resolution?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 32)

    public var isAvailable: Bool { device != nil && resolution != nil }

    public init() {
        open()
    }

    deinit {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// The current lid angle in degrees, or `nil` if the read failed.
    ///
    /// 0 means closed. A MacBook opens to roughly 130 degrees.
    public func angle() -> Double? {
        guard let resolution else { return nil }
        guard let bytes = read(reportID: resolution.reportID) else { return nil }
        guard bytes.first == UInt8(resolution.reportID) else { return nil }

        let degrees: Double
        switch resolution {
        case .hundredthsOfADegree:
            guard bytes.count >= 5 else { return nil }
            let raw = UInt32(bytes[1])
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3]) << 16
                | UInt32(bytes[4]) << 24
            degrees = Double(raw) / 100
        case .wholeDegrees:
            guard bytes.count >= 3 else { return nil }
            degrees = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        }

        guard degrees >= 0, degrees <= 360 else {
            lastRead.rejectedDegrees = degrees
            return nil
        }
        return degrees
    }

    // MARK: - Device

    private func open() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }
        self.manager = manager

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            // An external display can carry the same usage and reads 0.
            guard (IOHIDDeviceGetProperty(candidate, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue == true else {
                continue
            }
            device = candidate
            for format in [Resolution.hundredthsOfADegree, .wholeDegrees] {
                resolution = format
                if angle() != nil { return }
            }
        }
        device = nil
        resolution = nil
    }

    private func read(reportID: Int) -> [UInt8]? {
        lastRead = ReadTrace()
        guard let device else {
            lastRead.status = kIOReturnNoDevice
            return nil
        }
        var length = CFIndex(buffer.count)
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, &length)
        }
        lastRead.status = result
        lastRead.length = Int(length)
        guard result == kIOReturnSuccess, length > 0 else { return nil }
        let bytes = Array(buffer[0..<Int(length)])
        lastRead.bytes = bytes
        return bytes
    }
}
