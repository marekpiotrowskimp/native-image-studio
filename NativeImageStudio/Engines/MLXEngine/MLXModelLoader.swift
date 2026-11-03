import Domain
import Foundation
import Infrastructure

/// Result of an unload: what actually came back, measured.
public struct UnloadReport: Sendable, Equatable {
    public let footprintBeforeGB: Double
    public let footprintAfterGB: Double
    public let gpuActiveBeforeGB: Double
    public let gpuActiveAfterGB: Double
    public let gpuCacheAfterGB: Double
    public let seconds: Double
}

/// Picks the family adapter for a manifest and performs the release procedure.
public enum MLXModelLoader {
    public static func makeAdapter(for descriptor: ModelDescriptor) throws -> any MLXPipelineAdapter {
        guard descriptor.backend == .mlx else {
            throw GenerationError.backendFailure("Model \(descriptor.id) nie jest modelem MLX.")
        }
        switch descriptor.architecture {
        case "flux2":
            return try Flux2Adapter(descriptor: descriptor)
        case "zimage":
            return ZImageAdapter(descriptor: descriptor)
        default:
            throw GenerationError.backendFailure("Brak adaptera MLX dla architektury \(descriptor.architecture).")
        }
    }

    /// Release procedure (after the active generation has stopped):
    /// release pipeline references → synchronize GPU → clear MLX buffer cache → measure.
    /// Releasing references does not guarantee memory returns to the OS immediately,
    /// so the report carries before/after numbers.
    public static func release(_ adapter: any MLXPipelineAdapter, gpu: MLXGPUMemory) async -> UnloadReport {
        let start = ContinuousClock.now
        let footprintBefore = DarwinMemoryProbe.processFootprint().gigabytes
        let activeBefore = gpu.activeBytes.gigabytes
        gpu.synchronize()
        await adapter.release()
        gpu.synchronize()
        gpu.clearCache()
        let elapsed = ContinuousClock.now - start
        return UnloadReport(
            footprintBeforeGB: footprintBefore,
            footprintAfterGB: DarwinMemoryProbe.processFootprint().gigabytes,
            gpuActiveBeforeGB: activeBefore,
            gpuActiveAfterGB: gpu.activeBytes.gigabytes,
            gpuCacheAfterGB: gpu.cacheBytes.gigabytes,
            seconds: elapsed.seconds
        )
    }
}
