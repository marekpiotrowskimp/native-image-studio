import Infrastructure
import MLX

/// `GPUMemoryProvider` backed by MLX's allocator statistics.
public struct MLXGPUMemory: GPUMemoryProvider {
    public init() {}

    public var activeBytes: UInt64 { UInt64(max(0, Memory.activeMemory)) }
    public var cacheBytes: UInt64 { UInt64(max(0, Memory.cacheMemory)) }
    public var peakBytes: UInt64 { UInt64(max(0, Memory.peakMemory)) }

    public func clearCache() { Memory.clearCache() }
    public func resetPeak() { Memory.peakMemory = 0 }

    /// MLX evaluates lazily: dropping Swift references does not stop GPU work that is
    /// already scheduled. Wait for the GPU stream before freeing/clearing buffers.
    public func synchronize() { Stream.gpu.synchronize() }
}
