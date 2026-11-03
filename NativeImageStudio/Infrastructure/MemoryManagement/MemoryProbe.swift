import Darwin
import Foundation

public enum MemoryPressureLevel: String, Sendable, Codable, Comparable {
    case normal, warning, critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.normal, .warning, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public enum ThermalLevel: String, Sendable, Codable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

/// Point-in-time view of memory relevant for admission decisions. All sizes in bytes.
public struct MemorySnapshot: Sendable, Codable, Equatable {
    public var physicalBytes: UInt64
    /// Process physical footprint (what Activity Monitor shows as "Memory").
    public var processFootprintBytes: UInt64
    /// Memory the kernel considers available: `kern.memorystatus_level` (percent of RAM
    /// free incl. reclaimable file cache and compressible pages — the same measure the
    /// kernel uses for memory pressure), or free+inactive+purgeable+speculative pages
    /// if the sysctl is unavailable.
    public var systemAvailableBytes: UInt64
    public var pressure: MemoryPressureLevel
    public var thermal: ThermalLevel
    /// Inference backend allocator (MLX) stats; zero when no backend reports them.
    public var gpuActiveBytes: UInt64
    public var gpuCacheBytes: UInt64
    public var gpuPeakBytes: UInt64

    public init(
        physicalBytes: UInt64, processFootprintBytes: UInt64, systemAvailableBytes: UInt64,
        pressure: MemoryPressureLevel, thermal: ThermalLevel,
        gpuActiveBytes: UInt64 = 0, gpuCacheBytes: UInt64 = 0, gpuPeakBytes: UInt64 = 0
    ) {
        self.physicalBytes = physicalBytes
        self.processFootprintBytes = processFootprintBytes
        self.systemAvailableBytes = systemAvailableBytes
        self.pressure = pressure
        self.thermal = thermal
        self.gpuActiveBytes = gpuActiveBytes
        self.gpuCacheBytes = gpuCacheBytes
        self.gpuPeakBytes = gpuPeakBytes
    }
}

public extension UInt64 {
    var gigabytes: Double { Double(self) / 1_073_741_824 }
}

public extension Double {
    var bytesFromGB: UInt64 { UInt64(max(0, self) * 1_073_741_824) }
}

/// Backend allocator hooks (implemented by MLXEngine with `MLX.Memory`).
public protocol GPUMemoryProvider: Sendable {
    var activeBytes: UInt64 { get }
    var cacheBytes: UInt64 { get }
    var peakBytes: UInt64 { get }
    func clearCache()
    func resetPeak()
    /// Wait until all scheduled GPU work has finished.
    func synchronize()
}

public protocol SystemMemoryProbe: Sendable {
    func snapshot() -> MemorySnapshot
}

/// Reads Mach / sysctl statistics.
public struct DarwinMemoryProbe: SystemMemoryProbe {
    public let gpu: (any GPUMemoryProvider)?

    public init(gpu: (any GPUMemoryProvider)? = nil) {
        self.gpu = gpu
    }

    public func snapshot() -> MemorySnapshot {
        MemorySnapshot(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            processFootprintBytes: Self.processFootprint(),
            systemAvailableBytes: Self.systemAvailable(),
            pressure: Self.pressureLevel(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            gpuActiveBytes: gpu?.activeBytes ?? 0,
            gpuCacheBytes: gpu?.cacheBytes ?? 0,
            gpuPeakBytes: gpu?.peakBytes ?? 0
        )
    }

    public static func processFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Lifetime peak of the process physical footprint (backend-neutral: covers Core ML
    /// and MLX allocations alike).
    public static func processPeakFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : 0
    }

    public static func systemAvailable() -> UInt64 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, (1...100).contains(level) {
            return ProcessInfo.processInfo.physicalMemory / 100 * UInt64(level)
        }
        return pageBasedAvailable()
    }

    /// free + inactive + purgeable + speculative pages (conservative: ignores file cache
    /// in active pages and compressible anonymous memory).
    public static func pageBasedAvailable() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
        return pages * UInt64(pageSize)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public static func pressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}
