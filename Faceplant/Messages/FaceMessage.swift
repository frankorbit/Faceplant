import ARKit
import Foundation
import simd
import UIKit

/// 留言包的元数据，对应 manifest.json。
struct FaceMessageManifest: Codable, Hashable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var title: String
    /// 脸在保存时世界坐标下的变换（列主序 16 个数），和 worldmap.bin 同一坐标系
    var faceTransform: [Float]
    /// 脸相对参考图 anchor 的变换；没做出参考图时为 nil
    var faceRelativeToImage: [Float]?
    /// 参考图的物理宽度（米），按放置点离相机的距离估出来的
    var referenceImageWidth: Float?
    /// ARKit 校验过参考图足够清晰、有特征，重访时才拿它做识别
    var referenceImageUsable: Bool
    var hasWorldMap: Bool
    var deviceModel: String

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func write(to url: URL) throws {
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> FaceMessageManifest {
        try decoder.decode(FaceMessageManifest.self, from: Data(contentsOf: url))
    }
}

/// 种在某个地方的一条留言：目录 `<uuid>.facemessage`。
///
/// ```
/// <uuid>.facemessage/
/// ├── manifest.json
/// ├── recording.faceplant/   录制包的完整副本，删掉原录制也不影响留言
/// ├── worldmap.bin           ARWorldMap 归档，含脸的 anchor（名字 FaceMessage.anchorName）
/// ├── reference.jpg          放置点周围裁出的正立参考图，重访时当 ARReferenceImage
/// └── thumbnail.jpg          列表缩略图
/// ```
struct FaceMessage: Identifiable, Hashable {
    static let packageExtension = "facemessage"
    static let manifestFileName = "manifest.json"
    static let recordingDirectoryName = "recording.faceplant"
    static let worldMapFileName = "worldmap.bin"
    static let referenceImageFileName = "reference.jpg"
    static let thumbnailFileName = "thumbnail.jpg"
    /// 世界地图里脸的 anchor 名字，重访时按名字找回
    static let anchorName = "faceplant.message.face"

    let url: URL
    let manifest: FaceMessageManifest

    var id: String { url.lastPathComponent }
    var manifestURL: URL { url.appendingPathComponent(Self.manifestFileName) }
    var recordingURL: URL { url.appendingPathComponent(Self.recordingDirectoryName, isDirectory: true) }
    var worldMapURL: URL { url.appendingPathComponent(Self.worldMapFileName) }
    var referenceImageURL: URL { url.appendingPathComponent(Self.referenceImageFileName) }
    var thumbnailURL: URL { url.appendingPathComponent(Self.thumbnailFileName) }

    var faceTransform: simd_float4x4? { simd_float4x4(flattened: manifest.faceTransform) }
    var faceRelativeToImage: simd_float4x4? { manifest.faceRelativeToImage.flatMap { simd_float4x4(flattened: $0) } }

    static func load(url: URL) throws -> FaceMessage {
        let manifestURL = url.appendingPathComponent(manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw FaceplantError.messagePackageInvalid("缺少 manifest.json: \(url.lastPathComponent)")
        }
        let manifest = try FaceMessageManifest.load(from: manifestURL)
        guard manifest.formatVersion == FaceMessageManifest.currentFormatVersion else {
            throw FaceplantError.messagePackageInvalid("不支持的格式版本 \(manifest.formatVersion)")
        }
        return FaceMessage(url: url, manifest: manifest)
    }

    func loadRecording() throws -> FaceRecording {
        try FaceRecording.load(url: recordingURL)
    }

    /// 没存地图返回 nil；存了但读不出来按损坏抛错
    func loadWorldMap() throws -> ARWorldMap? {
        guard manifest.hasWorldMap else { return nil }
        let data = try Data(contentsOf: worldMapURL)
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw FaceplantError.messagePackageInvalid("worldmap.bin 解档为空")
        }
        return map
    }

    /// 参考图不可用或读不出来都返回 nil：它只是重定位的辅助手段，不该阻止重访
    func loadReferenceImage() -> ARReferenceImage? {
        guard manifest.referenceImageUsable, let width = manifest.referenceImageWidth, width > 0,
              let cgImage = UIImage(contentsOfFile: referenceImageURL.path)?.cgImage else { return nil }
        let image = ARReferenceImage(cgImage, orientation: .up, physicalWidth: CGFloat(width))
        image.name = id
        return image
    }
}
