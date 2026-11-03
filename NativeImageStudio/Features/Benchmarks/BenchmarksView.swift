import Infrastructure
import SwiftUI

/// Benchmark panel: comparable groups (equal model/backend/mode/inputs/resolution/steps)
/// and per-batch averages, from the app log.
public struct BenchmarksView: View {
    let log: BenchmarkLog
    @State private var records: [BenchmarkRecord] = []
    @State private var error: String?

    public init(log: BenchmarkLog) {
        self.log = log
    }

    public var body: some View {
        let summaries = BenchmarkSummary.summarize(records)
        let batches = BenchmarkSummary.batchAverages(records)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pomiary z \(records.count) generacji").font(.headline)
                Spacer()
                Button { reload() } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
            Text("Wiersze grupowane tylko przy identycznych warunkach (model, backend, tryb, liczba wejść, rozdzielczość, kroki). Peak: MLX — szczyt alokatora MLX; Core ML — szczyt footprintu procesu.")
                .font(.caption).foregroundStyle(.secondary)
            Table(summaries) {
                TableColumn("Model") { Text($0.key.model) }
                TableColumn("Backend") { Text($0.key.backend) }.width(60)
                TableColumn("Tryb (wejścia)") { Text("\($0.key.mode) (\($0.key.inputImageCount))") }.width(140)
                TableColumn("Rozdz.") { Text("\($0.key.width)×\($0.key.height)") }.width(90)
                TableColumn("Kroki") { Text("\($0.key.steps)") }.width(45)
                TableColumn("N") { Text("\($0.runs)") }.width(30)
                TableColumn("Śr. czas s") { Text(String(format: "%.1f (%.1f–%.1f)", $0.meanGenerationSeconds, $0.minGenerationSeconds, $0.maxGenerationSeconds)) }
                TableColumn("s/krok") { Text($0.meanSecondsPerStep.map { String(format: "%.2f", $0) } ?? "–") }.width(55)
                TableColumn("Peak GB") { Text(String(format: "%.2f", $0.maxPeakMemoryGB)) }.width(60)
                TableColumn("Termika") { Text($0.thermalStates.joined(separator: ",")) }
            }
            if !batches.isEmpty {
                Text("Partie").font(.headline)
                ForEach(batches, id: \.batch) { b in
                    Text(String(format: "%@ — %d zdjęć, średnio %.1f s/zdjęcie", b.batch, b.images, b.meanSeconds))
                        .font(.callout.monospacedDigit())
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding()
        .task { reload() }
    }

    private func reload() {
        do {
            records = try log.readAll()
            error = nil
        } catch {
            self.error = "Nie można odczytać \(log.fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
