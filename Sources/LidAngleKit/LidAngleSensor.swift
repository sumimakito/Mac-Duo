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
///
/// Reading a report is a round trip to the sensor coprocessor, which costs a
/// few hundred microseconds of CPU each time. The sensor can also push report 1
/// on its own: once a second by default, or at a set interval once its
/// `AppleSPUHIDDriver` is told to report. `startReporting` uses that, so a
/// watcher that only needs to notice the lid starting to move never polls.
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
    private var driver: io_object_t = 0
    private var pushBuffer: UnsafeMutablePointer<UInt8>?
    private var pushHandler: ((Double) -> Void)?
    /// Pushed reports land on the caller's queue; the handler is set and
    /// cleared from another.
    private let handlerLock = NSLock()
    private static let pushBufferSize = 64

    public var isAvailable: Bool { device != nil && resolution != nil }

    public init() {
        open()
    }

    deinit {
        stopReporting()
        if driver != 0 { IOObjectRelease(driver) }
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

    // MARK: - Pushed reports

    /// Starts the sensor pushing whole degree readings to `handler` on
    /// `queue`, about `interval` apart. Returns false when the sensor cannot
    /// push, and the caller has to poll.
    ///
    /// The interval is a setting on the sensor driver, shared by the whole
    /// system and kept after this process exits, so `stopReporting()` must
    /// run before exit.
    @discardableResult
    public func startReporting(
        interval: TimeInterval,
        queue: DispatchQueue,
        handler: @escaping (Double) -> Void
    ) -> Bool {
        guard let device, pushBuffer == nil else { return pushBuffer != nil }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.pushBufferSize)
        pushBuffer = buffer
        handlerLock.lock()
        pushHandler = handler
        handlerLock.unlock()
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.pushBufferSize, { context, result, _, _, reportID, report, length in
            guard let context, result == kIOReturnSuccess, reportID == 1, length >= 3 else { return }
            let sensor = Unmanaged<LidAngleSensor>.fromOpaque(context).takeUnretainedValue()
            let degrees = Double(UInt16(report[1]) | UInt16(report[2]) << 8)
            guard degrees <= 360 else { return }
            sensor.handlerLock.lock()
            let handler = sensor.pushHandler
            sensor.handlerLock.unlock()
            handler?(degrees)
        }, context)
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceActivate(device)
        setReportInterval(interval)
        return true
    }

    /// Changes how often pushed readings arrive. Zero leaves the sensor's own
    /// once a second.
    public func setReportInterval(_ interval: TimeInterval) {
        guard let driver = lidDriver() else { return }
        let microseconds = max(Int((interval * 1_000_000).rounded()), 0)
        IORegistryEntrySetCFProperty(driver, "SensorPropertyReportingState" as CFString, NSNumber(value: microseconds > 0 ? 1 : 0))
        IORegistryEntrySetCFProperty(driver, "SensorPropertyPowerState" as CFString, NSNumber(value: microseconds > 0 ? 1 : 0))
        IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, NSNumber(value: microseconds))
    }

    /// Puts the sensor back to its own once a second and stops the handler.
    public func stopReporting() {
        guard pushBuffer != nil else { return }
        setReportInterval(0)
        handlerLock.lock()
        pushHandler = nil
        handlerLock.unlock()
        // The callback stays registered on the activated device; with no
        // handler it returns at once. Unregistering from another queue races
        // a callback already running.
    }

    /// The `AppleSPUHIDDriver` behind the lid angle, which holds the report
    /// interval.
    private func lidDriver() -> io_object_t? {
        if driver != 0 { return driver }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let page = IORegistryEntryCreateCFProperty(entry, "PrimaryUsagePage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let usage = IORegistryEntryCreateCFProperty(entry, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            if page == 0x20, usage == 0x8A {
                driver = entry
                return entry
            }
            IOObjectRelease(entry)
        }
        return nil
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
