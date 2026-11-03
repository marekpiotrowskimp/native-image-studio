import Application
import CoreGraphics
import Domain
import SwiftUI

/// Progress of a running job: the live preview of the image being denoised (when the engine
/// reports one), a progress bar and the state label. While the model loads it also shows the
/// elapsed time and the coordinator's loading note, so a long Neural Engine compile is not
/// mistaken for a hang.
struct JobStatusView: View {
    let job: JobSnapshot

    var body: some View {
        VStack(spacing: 12) {
            if let preview = job.preview, let image = preview.cgImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(CGFloat(job.request.width) / CGFloat(max(1, job.request.height)), contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        Text("Podgląd · krok \(preview.step)/\(preview.totalSteps)\(preview.isApproximate ? " · przybliżony" : "")")
                            .font(.caption).padding(6)
                            .background(.thinMaterial, in: .rect(cornerRadius: 6)).padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Podgląd generowanego obrazu, krok \(preview.step) z \(preview.totalSteps)")
            }
            ProgressView(value: job.state.fraction).frame(maxWidth: 320)
            if job.state == .loading, let started = job.startedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("\(job.state.polishLabel) · \(Int(context.date.timeIntervalSince(started))) s")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                if let note = job.loadingNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }
            } else {
                Text(job.state.polishLabel).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(job.preview == nil ? 0 : 16)
    }
}

extension PreviewFrame {
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
