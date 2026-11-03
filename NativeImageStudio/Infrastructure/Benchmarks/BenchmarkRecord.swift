import Domain
import Foundation

/// One measurement row. Comparisons between backends are only valid for rows with
/// equal mode, resolution, steps and input count.
public struct BenchmarkRecord: Sendable, Codable, Equatable {
    public var model: String
    public var backend: String
    public var mode: String
    public var inputImageCount: Int
    public var quantization: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var seed: UInt64
    public var macOSVersion: String
    public var thermalState: String
    /// Load time for the first job after the model was not resident (nil for warm runs).
    public var coldLoadSeconds: Double?
    public var generationSeconds: Double
    public var secondsPerStep: Double
    public var peakMemoryGB: Double
    /// Process footprint right after the run (GB).
    public var footprintGB: Double
    /// Batch runs only.
    public var batchSize: Int?
    public var batchAverageSecondsPerImage: Double?
    public var note: String?
    public var date: Date

    public init(
        model: String, backend: String, mode: String, inputImageCount: Int, quantization: String,
        width: Int, height: Int, steps: Int, seed: UInt64,
        coldLoadSeconds: Double?, generationSeconds: Double, secondsPerStep: Double,
        peakMemoryGB: Double, footprintGB: Double,
        batchSize: Int? = nil, batchAverageSecondsPerImage: Double? = nil, note: String? = nil,
        thermal: ThermalLevel = ThermalLevel(ProcessInfo.processInfo.thermalState),
        date: Date = Date()
    ) {
        self.model = model
        self.backend = backend
        self.mode = mode
        self.inputImageCount = inputImageCount
        self.quantization = quantization
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.thermalState = thermal.rawValue
        self.coldLoadSeconds = coldLoadSeconds
        self.generationSeconds = generationSeconds
        self.secondsPerStep = secondsPerStep
        self.peakMemoryGB = peakMemoryGB
        self.footprintGB = footprintGB
        self.batchSize = batchSize
        self.batchAverageSecondsPerImage = batchAverageSecondsPerImage
        self.note = note
        self.date = date
    }

    public static let markdownHeader = """
        | model | backend | mode | inputs | quant | res | steps | seed | thermal | cold load s | gen s | s/step | peak GB | footprint GB | note |
        |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
        """

    public var markdownRow: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
        return "| \(model) | \(backend) | \(mode) | \(inputImageCount) | \(quantization) | \(width)×\(height) | \(steps) | \(seed) | \(thermalState) | \(f(coldLoadSeconds)) | \(f(generationSeconds)) | \(f(secondsPerStep)) | \(f(peakMemoryGB)) | \(f(footprintGB)) | \(note ?? "") |"
    }
}

/// Append-only JSON Lines log.
public struct BenchmarkLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func append(_ record: BenchmarkRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    public func readAll() throws -> [BenchmarkRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(BenchmarkRecord.self, from: Data($0.utf8)) }
    }
}
