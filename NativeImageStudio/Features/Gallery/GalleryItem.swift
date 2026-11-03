import Domain
import Foundation
import SwiftData

/// Gallery index row. The PNG + JSON sidecar on disk stay the source of truth;
/// this model makes browsing/filtering fast and links results to their inputs.
@Model
public final class GalleryItem {
    @Attribute(.unique) public var requestID: UUID
    public var filePath: String
    public var prompt: String
    public var negativePrompt: String?
    public var modeKind: String
    public var strength: Double?
    public var modelID: String
    public var backend: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var guidance: Double
    /// UInt64 seeds do not fit Int64; stored as text.
    public var seedText: String
    public var inputPaths: [String]
    public var inputHashes: [String]
    public var inputRoles: [String]
    public var batchID: UUID?
    public var createdAt: Date
    public var elapsedSeconds: Double
    public var favorite: Bool
    /// Removed from the gallery view but file kept on disk (so a disk re-import does not bring it back).
    public var isHidden: Bool = false

    public init(metadata m: GenerationMetadata, fileURL: URL, elapsedSeconds: Double) {
        requestID = m.requestID
        filePath = fileURL.path
        prompt = m.prompt
        negativePrompt = m.negativePrompt
        modeKind = m.mode.kind.rawValue
        if case .imageToImage(let s) = m.mode { strength = Double(s) } else { strength = nil }
        modelID = m.modelID
        backend = m.backend
        width = m.width
        height = m.height
        steps = m.steps
        guidance = Double(m.guidance)
        seedText = String(m.seed)
        inputPaths = m.inputs.map(\.path)
        inputHashes = m.inputs.map(\.sha256)
        inputRoles = m.inputs.map(\.role.rawValue)
        batchID = m.batchID
        createdAt = m.createdAt
        self.elapsedSeconds = elapsedSeconds
        favorite = false
    }

    public var fileURL: URL { URL(fileURLWithPath: filePath) }
    public var inputURLs: [URL] { inputPaths.map { URL(fileURLWithPath: $0) } }
    public var mode: ModeKind? { ModeKind(rawValue: modeKind) }
}
