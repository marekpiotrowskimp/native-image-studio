import Domain
import Foundation

/// Downloads the files of a Hugging Face model repository into a local directory.
public enum HuggingFaceDownloader {
    struct RemoteFile: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    /// Repository files minus git metadata, model cards and preview images.
    static func isPayload(_ path: String) -> Bool {
        !path.hasPrefix(".") && !path.hasSuffix(".md") && !path.hasSuffix(".png")
    }

    /// Downloads every payload file of `repo` at `revision` into `directory`.
    /// Files already present with the expected size are skipped.
    public static func download(repo: String, revision: String = "main", into directory: URL,
                                progress: (@Sendable (Double, String) -> Void)?) async throws {
        let listURL = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)?recursive=true")!
        let (data, response) = try await URLSession.shared.data(from: listURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GenerationError.backendFailure("Nie udało się pobrać listy plików \(repo).")
        }
        let files = try JSONDecoder().decode([RemoteFile].self, from: data)
            .filter { $0.type == "file" && isPayload($0.path) }
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        let fm = FileManager.default
        var done: Int64 = 0
        for file in files {
            let dest = directory.appendingPathComponent(file.path)
            if let size = file.size,
               let attrs = try? fm.attributesOfItem(atPath: dest.path),
               (attrs[.size] as? Int64) == size {
                done += size
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress?(Double(done) / Double(total), file.path)
            let remote = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let (tmp, resp) = try await URLSession.shared.download(from: remote)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw GenerationError.backendFailure("Błąd pobierania \(file.path).")
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            done += file.size ?? 0
        }
        progress?(1, "Gotowe")
    }
}
