import CoreGraphics
import Domain
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImagePersistenceError: Error, Sendable, Equatable, LocalizedError {
    case wouldOverwriteInput(URL)
    case encodeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .wouldOverwriteInput(let url): "Odmowa zapisu: \(url.lastPathComponent) jest plikiem wejściowym."
        case .encodeFailed(let url): "Nie udało się zapisać \(url.lastPathComponent)."
        }
    }
}

/// Writes generated images as new PNG files with a JSON metadata sidecar.
/// Never writes over an existing file or an input image.
public actor ImageRepository {
    public nonisolated let outputDirectory: URL
    private let fileManager = FileManager.default

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    public static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Native Image Studio", isDirectory: true)
    }

    /// Persist `image`, returning the new file URL. Inputs are passed explicitly so the
    /// repository can refuse to touch them even if a caller builds a colliding path.
    public func save(_ image: CGImage, metadata: GenerationMetadata, inputs: [URL]) throws -> URL {
        let day = Self.dayString(metadata.createdAt)
        let dir = outputDirectory.appendingPathComponent(day, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Self.stampString(metadata.createdAt)
        let base = "\(stamp)_\(metadata.mode.kind.rawValue)_s\(metadata.seed)"
        var url = dir.appendingPathComponent(base).appendingPathExtension("png")
        var suffix = 1
        while fileManager.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension("png")
            suffix += 1
        }
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        if inputs.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == standardized }) {
            throw ImagePersistenceError.wouldOverwriteInput(url)
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImagePersistenceError.encodeFailed(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImagePersistenceError.encodeFailed(url) }

        let data = try Self.encoder.encode(metadata)
        try data.write(to: Self.sidecarURL(for: url), options: .withoutOverwriting)
        return url
    }

    public nonisolated static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("json")
    }

    public func loadMetadata(for imageURL: URL) throws -> GenerationMetadata {
        let data = try Data(contentsOf: Self.sidecarURL(for: imageURL))
        return try Self.decoder.decode(GenerationMetadata.self, from: data)
    }

    /// All images with sidecars, newest first.
    public func allEntries() -> [(url: URL, metadata: GenerationMetadata)] {
        guard let enumerator = fileManager.enumerator(at: outputDirectory, includingPropertiesForKeys: nil) else { return [] }
        var result: [(URL, GenerationMetadata)] = []
        for case let url as URL in enumerator where url.pathExtension == "png" {
            if let meta = try? loadMetadata(for: url) { result.append((url, meta)) }
        }
        return result.sorted { $0.1.createdAt > $1.1.createdAt }
    }

    // MARK: Folders

    /// Gallery folders are real subdirectories of `<output>/Foldery/`, so they are visible in Finder;
    /// images outside it stay in their per-day directories.
    public nonisolated static let foldersDirectoryName = "Foldery"

    public nonisolated var foldersRoot: URL {
        outputDirectory.appendingPathComponent(Self.foldersDirectoryName, isDirectory: true)
    }

    /// Valid folder name, or nil: trimmed, without path separators, not hidden.
    public nonisolated static func sanitizedFolderName(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), name.count <= 100 else { return nil }
        return name
    }

    /// Folder of an image file, nil for images outside `Foldery/`.
    public nonisolated func folderName(of imageURL: URL) -> String? {
        let root = Self.canonicalComponents(foldersRoot)
        let parts = Self.canonicalComponents(imageURL)
        guard parts.count == root.count + 2, Array(parts.prefix(root.count)) == root else { return nil }
        return parts[root.count]
    }

    /// Path components that do not depend on the file existing: `standardizedFileURL` drops a
    /// leading /private only for existing paths, so a just-moved file would compare differently.
    nonisolated static func canonicalComponents(_ url: URL) -> [String] {
        var parts = url.standardized.pathComponents
        if parts.count > 2, parts[0] == "/", parts[1] == "private" { parts.remove(at: 1) }
        return parts
    }

    public nonisolated func folders() -> [String] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: foldersRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @discardableResult
    public nonisolated func createFolder(_ raw: String) throws -> String {
        guard let name = Self.sanitizedFolderName(raw) else { throw GalleryFolderError.invalidName(raw) }
        let url = foldersRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { throw GalleryFolderError.alreadyExists(name) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return name
    }

    /// Renames the directory; returns the new name. Callers update stored paths of moved images.
    public nonisolated func renameFolder(_ old: String, to raw: String) throws -> String {
        guard let name = Self.sanitizedFolderName(raw) else { throw GalleryFolderError.invalidName(raw) }
        guard name != old else { return name }
        let target = foldersRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { throw GalleryFolderError.alreadyExists(name) }
        try FileManager.default.moveItem(at: foldersRoot.appendingPathComponent(old, isDirectory: true), to: target)
        return name
    }

    /// Moves an image and its sidecar into `folder` (nil: back to its per-day directory).
    /// Never overwrites: a name collision gets a numeric suffix. Returns the new image URL.
    public nonisolated func moveImage(at url: URL, toFolder folder: String?, createdAt: Date) throws -> URL {
        let fm = FileManager.default
        let dir: URL
        if let folder {
            guard let name = Self.sanitizedFolderName(folder) else { throw GalleryFolderError.invalidName(folder) }
            dir = foldersRoot.appendingPathComponent(name, isDirectory: true)
        } else {
            dir = outputDirectory.appendingPathComponent(Self.dayString(createdAt), isDirectory: true)
        }
        if Self.canonicalComponents(url.deletingLastPathComponent()) == Self.canonicalComponents(dir) { return url }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        var target = dir.appendingPathComponent(url.lastPathComponent)
        var suffix = 1
        while fm.fileExists(atPath: target.path) || fm.fileExists(atPath: Self.sidecarURL(for: target).path) {
            target = dir.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension(url.pathExtension)
            suffix += 1
        }
        try fm.moveItem(at: url, to: target)
        let sidecar = Self.sidecarURL(for: url)
        if fm.fileExists(atPath: sidecar.path) {
            do {
                try fm.moveItem(at: sidecar, to: Self.sidecarURL(for: target))
            } catch {
                try? fm.moveItem(at: target, to: url)  // keep the pair together
                throw error
            }
        }
        return target
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func components(_ date: Date) -> DateComponents {
        Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    }

    static func dayString(_ date: Date) -> String {
        let c = components(date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func stampString(_ date: Date) -> String {
        let c = components(date)
        return String(format: "%02d%02d%02d-%03d", c.hour!, c.minute!, c.second!, c.nanosecond! / 1_000_000)
    }
}

/// Builds metadata input records (path + SHA-256) for a request.
public enum InputProvenance {
    public static func records(for request: GenerationRequest) -> [GenerationMetadata.InputRecord] {
        var items = request.inputImages.map { ($0.sourceURL, $0.role) }
        if case .inpainting(let mask) = request.mode { items.append((mask.sourceURL, .mask)) }
        return items.map { url, role in
            GenerationMetadata.InputRecord(
                path: url.path,
                sha256: (try? ImageInputProcessor.sha256(of: url)) ?? "",
                role: role
            )
        }
    }
}

public enum GalleryFolderError: Error, Sendable, Equatable, LocalizedError {
    case invalidName(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "Nieprawidłowa nazwa folderu: „\(name)”."
        case .alreadyExists(let name): "Folder „\(name)” już istnieje."
        }
    }
}
