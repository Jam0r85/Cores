import Foundation
import IOKit
import IOKit.ps

/// The internal battery: charge, whether it's plugged in and charging, and cycle count.
struct BatteryReading: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case onBattery
        case charging
        case charged     // plugged in and full
        case notCharging // plugged in but holding its charge (Optimized Battery Charging or a charge limit)
    }

    var charge: Int // percent
    var state: State
    /// Until empty on battery, or until full while charging. Nil while macOS is still estimating.
    var minutesRemaining: Int?
    var cycles: Int?
    /// Watts flowing out of the battery (on battery) or into it (charging). Nil when it's idle.
    var power: Double?
}

/// Reads the battery through the public power source API, plus the cycle count from the
/// battery's IORegistry entry. On a Mac without a battery `hasBattery` is false and it's never read.
final class BatterySampler {
    let hasBattery: Bool
    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        hasBattery = Self.internalBattery() != nil
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    func sample() -> BatteryReading? {
        guard hasBattery, let info = Self.internalBattery(), let current = info[kIOPSCurrentCapacityKey] as? Int else { return nil }
        let maximum = info[kIOPSMaxCapacityKey] as? Int ?? 100 // a percentage scale on Apple silicon
        let pluggedIn = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let state: BatteryReading.State =
            !pluggedIn ? .onBattery
            : info[kIOPSIsChargingKey] as? Bool == true ? .charging
            : info[kIOPSIsChargedKey] as? Bool == true ? .charged
            : .notCharging
        let minutes: Int? = switch state {
        case .onBattery: info[kIOPSTimeToEmptyKey] as? Int
        case .charging: info[kIOPSTimeToFullChargeKey] as? Int
        case .charged, .notCharging: nil
        }
        return BatteryReading(charge: maximum > 0 ? min(100, Int((Double(current) / Double(maximum) * 100).rounded())) : current,
                              state: state,
                              minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil }, // -1 while estimating
                              cycles: property("CycleCount").map { Int($0) },
                              power: power())
    }

    /// Current (mA, negative while discharging) times voltage (mV).
    private func power() -> Double? {
        guard let amperage = property("Amperage"), let voltage = property("Voltage") else { return nil }
        let watts = abs(Double(amperage) * Double(voltage)) / 1_000_000
        return watts >= 0.05 ? watts : nil
    }

    /// Signed even when the registry stores a negative number as a huge unsigned one.
    private func property(_ key: String) -> Int64? {
        guard service != 0 else { return nil }
        return (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.int64Value
    }

    private static func internalBattery() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  info[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            return info
        }
        return nil
    }
}
