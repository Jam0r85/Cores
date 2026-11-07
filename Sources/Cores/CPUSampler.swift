import Darwin

/// A set of identical cores, e.g. the 6 "Super" cores on an M5 Pro.
struct CoreCluster: Identifiable, Sendable {
    let id: Int            // perf level: 0 is the fastest tier
    let name: String       // name macOS gives the tier ("Super", "Performance", "Efficiency"...)
    let cpus: Range<Int>   // logical CPU numbers in this tier
}

/// Reads per-core load from the kernel's tick counters.
final class CPUSampler {
    private struct Ticks { var user, system, idle, nice: UInt32 }

    let clusters: [CoreCluster]
    let chipName: String
    private let host = mach_host_self()
    private var previous: [Ticks] = []

    init() {
        chipName = Sysctl.string("machdep.cpu.brand_string") ?? "Mac"
        clusters = Self.detectClusters()
    }

    /// Load per logical CPU (0...1) since the previous call. Nil on the very first call.
    func sample() -> [Double]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        let current = (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            return Ticks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                         system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                         idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                         nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        return zip(current, previous).map { now, before in
            // Counters can wrap, so subtract with overflow.
            let busy = Double((now.user &- before.user) &+ (now.system &- before.system) &+ (now.nice &- before.nice))
            let idle = Double(now.idle &- before.idle)
            return busy + idle > 0 ? busy / (busy + idle) : 0
        }
    }

    /// Apple Silicon numbers the slowest tier's CPUs first, so walk the perf levels from the last one.
    private static func detectClusters() -> [CoreCluster] {
        let total = Sysctl.int("hw.ncpu") ?? 1
        guard let levels = Sysctl.int("hw.nperflevels"), levels > 0 else {
            return [CoreCluster(id: 0, name: "Cores", cpus: 0..<total)]
        }
        var clusters: [CoreCluster] = []
        var next = 0
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let count = Sysctl.int("hw.perflevel\(level).logicalcpu") ?? 0
            guard count > 0 else { continue }
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)"
            clusters.append(CoreCluster(id: level, name: name, cpus: next..<min(next + count, total)))
            next += count
        }
        return clusters.sorted { $0.id < $1.id }
    }
}

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
