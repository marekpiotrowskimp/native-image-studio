import Application
import Domain
import Foundation
import Infrastructure

/// Turns completed jobs into `BenchmarkRecord`s (app-wide JSONL log).
public struct BenchmarkRecorder: Sendable {
    public let log: BenchmarkLog

    public init(log: BenchmarkLog) {
        self.log = log
    }

    public static var defaultLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/benchmarks.jsonl")
    }

    public static func record(for image: GeneratedImage, model: ModelDescriptor?) -> BenchmarkRecord {
        let m = image.metadata
        let thermal = image.stats.flatMap { ThermalLevel(rawValue: $0.thermalState) }
            ?? ThermalLevel(ProcessInfo.processInfo.thermalState)
        return BenchmarkRecord(
            model: m.modelID, backend: m.backend, mode: m.mode.kind.rawValue,
            inputImageCount: m.inputs.filter { $0.role != .mask }.count,
            quantization: model?.quantization ?? "?",
            width: m.width, height: m.height, steps: m.steps, seed: m.seed,
            coldLoadSeconds: nil, generationSeconds: image.elapsedSeconds,
            secondsPerStep: image.stats?.secondsPerStep ?? 0,
            peakMemoryGB: image.stats?.peakMemoryGB ?? 0,
            footprintGB: DarwinMemoryProbe.processFootprint().gigabytes,
            note: m.batchID.map { "batch:\($0.uuidString.prefix(8))" } ?? "app",
            thermal: thermal, date: m.createdAt)
    }

    public func append(_ image: GeneratedImage, model: ModelDescriptor?) {
        try? log.append(Self.record(for: image, model: model))
    }
}
