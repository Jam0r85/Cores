import CSensors

struct TempReading: Sendable, Equatable {
    var average: Double
    var peak: Double
}

struct FanReading: Identifiable, Sendable, Equatable {
    let id: Int
    var rpm: Double
    var maxRPM: Double?
}

struct SensorSnapshot: Sendable {
    var cpu: TempReading?
    var gpu: TempReading?
    var soc: TempReading?
    var ssd: TempReading?
    var battery: TempReading?
    var fans: [FanReading] = []
}

/// Reads temperatures and fans. There is no public API for these on Apple Silicon, so this
/// uses the SMC (CPU/GPU/fans) and the HID sensor hub (SSD, battery, and SoC die as a CPU fallback).
final class SensorSampler {
    private var cpuKeys: [smc_key_t] = []
    private var gpuKeys: [smc_key_t] = []
    private var fanKeys: [(actual: smc_key_t, max: smc_key_t?)] = []
    private var socSensors: [Int32] = []
    private var ssdSensors: [Int32] = []
    private var batterySensors: [Int32] = []

    init() {
        if smc_open() == 0 { discoverSMCKeys() }
        if hid_open() == 0 { discoverHIDSensors() }
    }

    /// Without SMC CPU sensors, the HID SoC sensors stand in for CPU temperature and need reading every tick.
    var needsHIDEveryTick: Bool { cpuKeys.isEmpty }

    func sampleTemps() -> (cpu: TempReading?, gpu: TempReading?) {
        (summarize(cpuKeys.compactMap(read)), summarize(gpuKeys.compactMap(read)))
    }

    func sampleFans() -> [FanReading] {
        fanKeys.enumerated().compactMap { index, keys in
            guard let rpm = readRaw(keys.actual) else { return nil }
            return FanReading(id: index, rpm: max(0, rpm), maxRPM: keys.max.flatMap { readRaw($0) })
        }
    }

    /// The ~40 SoC die sensors are only read when there are no SMC CPU sensors to use instead
    /// (they're not shown otherwise), which leaves just the SSD and battery: a few ms instead of ~30.
    func sampleHID() -> (soc: TempReading?, ssd: TempReading?, battery: TempReading?) {
        (cpuKeys.isEmpty ? summarize(socSensors.compactMap(readHID)) : nil,
         summarize(ssdSensors.compactMap(readHID)),
         summarize(batterySensors.compactMap(readHID)))
    }

    // MARK: - Discovery

    private func discoverSMCKeys() {
        for index in 0..<smc_key_count() {
            var key = smc_key_t()
            guard smc_key_at_index(index, &key) == 0 else { continue }
            let name = FourCC.string(key.key)
            if name.hasPrefix("Tp") || name.hasPrefix("Te") {
                cpuKeys.append(key)
            } else if name.hasPrefix("Tg") {
                gpuKeys.append(key)
            }
        }
        // Drop sensors that don't report a believable value right now (unpopulated slots).
        cpuKeys = cpuKeys.filter { read($0) != nil }
        gpuKeys = gpuKeys.filter { read($0) != nil }
        // The M5 Pro has ~60 GPU sensors that all read within half a degree of each other.
        // An even spread of 16 gives the same average for a quarter of the reads.
        if gpuKeys.count > 16 {
            let step = Double(gpuKeys.count) / 16
            gpuKeys = (0..<16).map { gpuKeys[Int(Double($0) * step)] }
        }

        var count = smc_key_t()
        if smc_key_lookup("FNum", &count) == 0, let fans = readRaw(count), fans > 0 {
            for index in 0..<Int(fans) {
                var actual = smc_key_t(), maximum = smc_key_t()
                guard smc_key_lookup("F\(index)Ac", &actual) == 0 else { continue }
                let hasMax = smc_key_lookup("F\(index)Mx", &maximum) == 0
                fanKeys.append((actual, hasMax ? maximum : nil))
            }
        }
    }

    private func discoverHIDSensors() {
        for index in 0..<hid_service_count() {
            let name = String(cString: hid_service_name(index))
            if name.hasPrefix("PMU tdie") {
                socSensors.append(index)
            } else if name.hasPrefix("NAND") {
                ssdSensors.append(index)
            } else if name.contains("battery") {
                batterySensors.append(index)
            }
        }
    }

    // MARK: - Reading

    private func readRaw(_ key: smc_key_t) -> Double? {
        var key = key
        var value = 0.0
        return smc_read_value(&key, &value) == 0 ? value : nil
    }

    private func read(_ key: smc_key_t) -> Double? {
        readRaw(key).flatMap(Self.plausible)
    }

    private func readHID(_ index: Int32) -> Double? {
        var value = 0.0
        return hid_read_temperature(index, &value) == 0 ? Self.plausible(value) : nil
    }

    private static func plausible(_ celsius: Double) -> Double? {
        (5...130).contains(celsius) ? celsius : nil
    }

    private func summarize(_ values: [Double]) -> TempReading? {
        guard !values.isEmpty else { return nil }
        return TempReading(average: values.reduce(0, +) / Double(values.count), peak: values.max() ?? 0)
    }
}

enum FourCC {
    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
