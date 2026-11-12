import Darwin
import Foundation

/// The Mac's unified memory, broken down the way Activity Monitor does it.
struct MemoryReading: Sendable, Equatable {
    enum Pressure: Sendable, Equatable { case normal, warning, critical }

    var used: UInt64       // app + wired + compressed: Activity Monitor's "Memory Used"
    var total: UInt64      // physical memory
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var pressure: Pressure?
}

final class MemorySampler {
    private let host = mach_host_self()
    private let total = ProcessInfo.processInfo.physicalMemory
    private let pageSize: UInt64

    init() {
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : UInt64(getpagesize())
    }

    /// App memory (anonymous pages that can't simply be dropped) + wired + compressed,
    /// which is how Activity Monitor arrives at "Memory Used".
    func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let anonymous = UInt64(stats.internal_page_count)
        let app = (anonymous - min(UInt64(stats.purgeable_count), anonymous)) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        // The same level macOS uses to decide when to start compressing and swapping.
        let pressure: MemoryReading.Pressure? = switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
        return MemoryReading(used: min(app + wired + compressed, total), total: total,
                             app: app, wired: wired, compressed: compressed, pressure: pressure)
    }
}
