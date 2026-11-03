import Foundation

/// 录制包的元数据，对应 manifest.json。
struct FaceRecordingManifest: Codable, Hashable {
    var formatVersion: Int
    var createdAt: Date
    var duration: TimeInterval
    var vertexCount: Int
    var meshFrameCount: Int
    var textureSize: Int
    var hasBlendShapes: Bool
    var deviceModel: String

    static let currentFormatVersion = 1

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

    static func load(from url: URL) throws -> FaceRecordingManifest {
        try decoder.decode(FaceRecordingManifest.self, from: Data(contentsOf: url))
    }
}
