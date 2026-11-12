import Foundation
import IOKit

/// The startup disk's free space, and how fast all disks are reading and writing.
struct DiskReading: Sendable, Equatable {
    var free: UInt64?     // what Finder calls Available (includes space macOS can free up)
    var total: UInt64?
    var readRate: Double? // bytes per second, summed over every disk; nil on the first read
    var writeRate: Double?
}

final class DiskSampler {
    private var previous: (time: Date, read: UInt64, written: UInt64)?
    private var capacity: (free: UInt64?, total: UInt64?) = (nil, nil)
    private var lastCapacityRead = Date.distantPast

    func sample() -> DiskReading {
        let now = Date()
        // Free space barely moves and is the slow part, so it's only looked up every 30 s.
        if now.timeIntervalSince(lastCapacityRead) >= 30 {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            capacity = (values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) },
                        values?.volumeTotalCapacity.map { UInt64(max($0, 0)) })
            lastCapacityRead = now
        }

        var reading = DiskReading(free: capacity.free, total: capacity.total)
        guard let totals = Self.bytesTransferred() else { return reading }
        if let previous, now > previous.time {
            let seconds = now.timeIntervalSince(previous.time)
            // A disk being ejected makes the totals go down; that read just counts as idle.
            reading.readRate = Double(totals.read &- min(previous.read, totals.read)) / seconds
            reading.writeRate = Double(totals.written &- min(previous.written, totals.written)) / seconds
        }
        previous = (now, totals.read, totals.written)
        return reading
    }

    /// Bytes read and written since boot, from each disk driver's statistics in the I/O registry.
    private static func bytesTransferred() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }
}
