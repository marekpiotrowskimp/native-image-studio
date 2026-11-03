import Foundation
import os

/// Timestamped job/model-load stages in the unified log, with the process footprint,
/// so a slow start can be attributed to a stage after the fact:
/// `log show --last 10m --predicate 'subsystem == "NativeImageStudio"' --style compact`
public enum StageLog {
    private static let logger = Logger(subsystem: "NativeImageStudio", category: "stages")

    public static func note(_ message: String) {
        let footprint = String(format: "%.2f", DarwinMemoryProbe.processFootprint().gigabytes)
        logger.notice("\(message, privacy: .public) [footprint \(footprint, privacy: .public) GB]")
    }

    /// Runs `body`, logging its start and duration.
    public static func measure<T>(_ stage: String, _ body: () async throws -> T) async rethrows -> T {
        note("\(stage): start")
        let start = ContinuousClock.now
        defer { note(String(format: "%@: %.2f s", stage, (ContinuousClock.now - start).seconds)) }
        return try await body()
    }
}
