import Application
import Domain
import SwiftUI

/// Active job, queue (with priority changes) and recent results.
public struct QueueView: View {
    let jobs: JobsStore

    public init(jobs: JobsStore) {
        self.jobs = jobs
    }

    public var body: some View {
        List {
            if let active = jobs.activeJob {
                Section("Aktywne") { JobRow(job: active, jobs: jobs) }
            }
            if !jobs.queuedJobs.isEmpty {
                Section("Kolejka (\(jobs.queuedJobs.count))") {
                    ForEach(jobs.queuedJobs) { JobRow(job: $0, jobs: jobs) }
                }
            }
            let finished = jobs.sortedJobs.filter(\.state.isTerminal).prefix(30)
            if !finished.isEmpty {
                Section {
                    ForEach(Array(finished)) { JobRow(job: $0, jobs: jobs) }
                } header: {
                    HStack {
                        Text("Zakończone")
                        Spacer()
                        Button("Wyczyść") { jobs.clearFinished() }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if jobs.jobs.isEmpty {
                Text("Kolejka jest pusta").foregroundStyle(.secondary)
            }
        }
    }
}

struct JobRow: View {
    let job: JobSnapshot
    let jobs: JobsStore

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.request.prompt).lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.state.polishLabel)
                    Text("·")
                    Text(job.request.mode.kind.polishName)
                    if job.batchID != nil { Text("· partia") }
                    if case .failed(let msg) = job.state { Text("· \(msg)").foregroundStyle(.red).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !job.state.isTerminal, job.state != .queued {
                    ProgressView(value: job.state.fraction).controlSize(.small)
                }
                ForEach(job.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
            }
            Spacer()
            if job.state == .queued {
                Menu {
                    ForEach(JobPriority.allCases, id: \.self) { p in
                        Button(p.polishName) { jobs.setPriority(job.id, p) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton).frame(width: 28)
                .help("Priorytet")
            }
            if !job.state.isTerminal {
                Button { jobs.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Anuluj")
            }
        }
    }

    @ViewBuilder var icon: some View {
        switch job.state {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        default: ProgressView().controlSize(.small)
        }
    }
}

public extension ModeKind {
    var polishName: String {
        switch self {
        case .textToImage: "Tekst → obraz"
        case .imageToImage: "Transformacja"
        case .referenceEdit: "Referencje"
        case .inpainting: "Inpainting"
        }
    }
}

public extension JobPriority {
    var polishName: String {
        switch self {
        case .low: "Niski"
        case .normal: "Normalny"
        case .high: "Wysoki"
        }
    }
}
