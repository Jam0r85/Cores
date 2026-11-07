import Darwin
import Foundation

/// The Mac's unified memory: how much is in use overall, and the GPU's share of it.
struct MemoryReading: Sendable, Equatable {
    var used: UInt64   // bytes, counted the way Activity Monitor's "Memory Used" is
    var total: UInt64  // physical memory
    var gpu: GPUMemoryReading?
}

final class MemorySampler {
    private let host = mach_host_self()
    private let total = ProcessInfo.processInfo.physicalMemory
    private let pageSize: UInt64
    private let gpu = GPUMemorySampler()

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
        let appPages = anonymous - min(UInt64(stats.purgeable_count), anonymous)
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return MemoryReading(used: min(usedPages * pageSize, total), total: total, gpu: gpu.sample())
    }
}
