import Foundation

/// 一个已完成的录制包：目录 `<uuid>.faceplant`，内含 manifest、拓扑、顶点流、贴图视频、缩略图。
struct FaceRecording: Identifiable, Hashable {
    static let packageExtension = "faceplant"
    static let manifestFileName = "manifest.json"
    static let topologyFileName = "topology.bin"
    static let meshFileName = "mesh.bin"
    static let textureFileName = "texture.mov"
    static let thumbnailFileName = "thumbnail.jpg"

    let url: URL
    let manifest: FaceRecordingManifest

    var id: String { url.lastPathComponent }
    var manifestURL: URL { url.appendingPathComponent(Self.manifestFileName) }
    var topologyURL: URL { url.appendingPathComponent(Self.topologyFileName) }
    var meshURL: URL { url.appendingPathComponent(Self.meshFileName) }
    var textureURL: URL { url.appendingPathComponent(Self.textureFileName) }
    var thumbnailURL: URL { url.appendingPathComponent(Self.thumbnailFileName) }

    static func load(url: URL) throws -> FaceRecording {
        let manifestURL = url.appendingPathComponent(manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw FaceplantError.recordingPackageInvalid("缺少 manifest.json: \(url.lastPathComponent)")
        }
        let manifest = try FaceRecordingManifest.load(from: manifestURL)
        guard manifest.formatVersion == FaceRecordingManifest.currentFormatVersion else {
            throw FaceplantError.recordingPackageInvalid("不支持的格式版本 \(manifest.formatVersion)")
        }
        return FaceRecording(url: url, manifest: manifest)
    }

    func loadTopology() throws -> FaceMeshTopology {
        try FaceMeshTopology(contentsOf: topologyURL)
    }

    func loadMeshFrames() throws -> [FaceMeshFrame] {
        try MeshStreamReader.read(url: meshURL)
    }
}
