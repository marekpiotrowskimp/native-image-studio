import Foundation

/// Aggregates benchmark rows into comparable groups. Rows are only grouped together
/// when model, backend, mode, input count, resolution, steps and quantization match —
/// the "equivalent conditions" rule for backend comparisons.
public struct BenchmarkSummary: Sendable, Equatable, Identifiable {
    public struct Key: Hashable, Sendable {
        public let model: String
        public let backend: String
        public let mode: String
        public let inputImageCount: Int
        public let quantization: String
        public let width: Int
        public let height: Int
        public let steps: Int
    }

    public let key: Key
    public let runs: Int
    public let meanGenerationSeconds: Double
    public let minGenerationSeconds: Double
    public let maxGenerationSeconds: Double
    public let meanSecondsPerStep: Double?
    public let maxPeakMemoryGB: Double
    public let thermalStates: [String]

    public var id: Key { key }

    /// Excludes cancelled runs and rows explicitly marked as not comparable.
    public static func summarize(_ records: [BenchmarkRecord]) -> [BenchmarkSummary] {
        let usable = records.filter { r in
            let note = r.note ?? ""
            return !note.contains("cancelled") && r.generationSeconds > 0
        }
        let groups = Dictionary(grouping: usable) {
            Key(model: $0.model, backend: $0.backend, mode: $0.mode, inputImageCount: $0.inputImageCount,
                quantization: $0.quantization, width: $0.width, height: $0.height, steps: $0.steps)
        }
        return groups.map { key, rows in
            let gen = rows.map(\.generationSeconds)
            let sps = rows.map(\.secondsPerStep).filter { $0 > 0 }
            return BenchmarkSummary(
                key: key, runs: rows.count,
                meanGenerationSeconds: gen.reduce(0, +) / Double(gen.count),
                minGenerationSeconds: gen.min() ?? 0,
                maxGenerationSeconds: gen.max() ?? 0,
                meanSecondsPerStep: sps.isEmpty ? nil : sps.reduce(0, +) / Double(sps.count),
                maxPeakMemoryGB: rows.map(\.peakMemoryGB).max() ?? 0,
                thermalStates: Array(Set(rows.map(\.thermalState))).sorted())
        }
        .sorted { a, b in
            if a.key.model != b.key.model { return a.key.model < b.key.model }
            if a.key.mode != b.key.mode { return a.key.mode < b.key.mode }
            return a.key.inputImageCount < b.key.inputImageCount
        }
    }

    /// Mean seconds per image for each batch (records carrying `batchSize`).
    public struct BatchAverage: Sendable, Equatable {
        public let batch: String
        public let images: Int
        public let meanSeconds: Double
    }

    public static func batchAverages(_ records: [BenchmarkRecord]) -> [BatchAverage] {
        let batched = records.filter { $0.note?.hasPrefix("batch:") == true }
        let groups = Dictionary(grouping: batched) { $0.note ?? "" }
        var result: [BatchAverage] = []
        for (note, rows) in groups {
            let total = rows.reduce(0.0) { $0 + $1.generationSeconds }
            result.append(BatchAverage(batch: String(note.dropFirst("batch:".count)), images: rows.count,
                                       meanSeconds: total / Double(rows.count)))
        }
        return result.sorted { $0.batch < $1.batch }
    }
}
