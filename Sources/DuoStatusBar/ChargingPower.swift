import Foundation
import IOKit

/// Battery-side estimate, not adapter rating or wall power. Registry keys may
/// be unavailable on some Macs; never substitute adapter capacity for a reading.
final class ChargingPower {
    static func isCharging() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func flag(_ key: String) -> Bool? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue
        }
        if flag("ExternalConnected") == false { return false }
        return flag("IsCharging")
    }

    private var lastRead: TimeInterval = -.infinity
    private var cached: Double?

    func sample(isCharging: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        guard isCharging else {
            cached = nil
            lastRead = -.infinity
            return nil
        }
        guard now - lastRead >= 15 else { return cached }
        lastRead = now
        cached = nil
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        }
        guard number("IsCharging")?.boolValue == true,
              let voltage = number("Voltage"), let current = number("Amperage") else { return nil }
        cached = Self.watts(millivolts: voltage.doubleValue, milliamps: current.doubleValue)
        return cached
    }

    static func watts(millivolts: Double, milliamps: Double) -> Double? {
        guard millivolts.isFinite, milliamps.isFinite,
              millivolts > 0, millivolts < 100_000,
              milliamps >= 0, milliamps < 100_000 else { return nil }
        return millivolts * milliamps / 1_000_000
    }
}
