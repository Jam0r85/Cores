import IOKit
import Metal

/// GPU memory on Apple Silicon. There's no separate VRAM: the GPU draws from the same unified
/// memory as everything else, so this reports its share of it.
struct GPUMemoryReading: Sendable, Equatable {
    var inUse: UInt64      // bytes the GPU is actively using
    var allocated: UInt64  // bytes the GPU driver has set aside (includes caches it can give back)
    var limit: UInt64?     // most the GPU is allowed to use (Metal's recommended working set)
}

final class GPUMemorySampler {
    private let service: io_service_t
    private let limit: UInt64?

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        limit = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// Reads the GPU driver's own statistics from the I/O registry (public API, no special access).
    func sample() -> GPUMemoryReading? {
        guard service != 0,
              let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
              let stats = property.takeRetainedValue() as? [String: Any],
              let inUse = (stats["In use system memory"] as? NSNumber)?.uint64Value,
              let allocated = (stats["Alloc system memory"] as? NSNumber)?.uint64Value
        else { return nil }
        return GPUMemoryReading(inUse: inUse, allocated: max(allocated, inUse), limit: limit)
    }
}
