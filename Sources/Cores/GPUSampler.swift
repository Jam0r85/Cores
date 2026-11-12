import IOKit
import Metal

/// The GPU: how busy it is and its share of unified memory. Apple silicon has no separate VRAM,
/// so the GPU draws from the same memory as everything else.
struct GPUReading: Sendable, Equatable {
    var utilization: Double? // 0...1
    var memoryInUse: UInt64     // bytes the GPU is actively using
    var memoryAllocated: UInt64 // bytes the GPU driver has set aside (includes caches it can give back)
}

final class GPUSampler {
    let coreCount: Int?
    /// Most memory the GPU is allowed to use (Metal's recommended working set).
    let memoryLimit: UInt64?
    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        memoryLimit = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize
        coreCount = service == 0 ? nil
            : IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// Reads the GPU driver's own statistics from the I/O registry (public API, no special access).
    func sample() -> GPUReading? {
        guard service != 0,
              let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
              let stats = property.takeRetainedValue() as? [String: Any],
              let inUse = (stats["In use system memory"] as? NSNumber)?.uint64Value,
              let allocated = (stats["Alloc system memory"] as? NSNumber)?.uint64Value
        else { return nil }
        let utilization = (stats["Device Utilization %"] as? NSNumber).map { min(max($0.doubleValue / 100, 0), 1) }
        return GPUReading(utilization: utilization, memoryInUse: inUse, memoryAllocated: max(allocated, inUse))
    }
}
