import Foundation
import Darwin

private let host = mach_host_self()

public struct CPUSampler {
    private var previous: host_cpu_load_info?

    public init() {}

    /// Busy fraction (0...1) of all cores since the previous call. The first call returns 0.
    public mutating func sample() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        defer { previous = info }
        guard let p = previous?.cpu_ticks else { return 0 }
        let t = info.cpu_ticks // (user, system, idle, nice)
        let user = Double(t.0 &- p.0), system = Double(t.1 &- p.1)
        let idle = Double(t.2 &- p.2), nice = Double(t.3 &- p.3)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total : 0
    }
}

public struct MemoryInfo: Equatable, Sendable {
    public var used: UInt64
    public var total: UInt64
    public var swapUsed: UInt64

    public var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func current() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        // Same as Activity Monitor's "Memory Used": app memory + wired + compressed.
        let anonymous = UInt64(stats.internal_page_count)
        let app = anonymous - min(UInt64(stats.purgeable_count), anonymous)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        return MemoryInfo(used: used, total: ProcessInfo.processInfo.physicalMemory, swapUsed: swap.xsu_used)
    }
}

public struct DiskInfo: Equatable, Sendable {
    public var free: Int64
    public var total: Int64

    public var usedFraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }

    public static func current() -> DiskInfo {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        return DiskInfo(
            free: values?.volumeAvailableCapacityForImportantUsage ?? 0,
            total: Int64(values?.volumeTotalCapacity ?? 0)
        )
    }
}

public func formatBytes<T: BinaryInteger>(_ bytes: T, style: ByteCountFormatter.CountStyle = .file) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: style)
}
