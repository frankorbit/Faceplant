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
    /// texture.mov 里有没有音轨。M1 的旧包没有这个字段，按 false 读
    var hasAudio: Bool

    static let currentFormatVersion = 1

    init(
        formatVersion: Int, createdAt: Date, duration: TimeInterval, vertexCount: Int, meshFrameCount: Int,
        textureSize: Int, hasBlendShapes: Bool, deviceModel: String, hasAudio: Bool
    ) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.duration = duration
        self.vertexCount = vertexCount
        self.meshFrameCount = meshFrameCount
        self.textureSize = textureSize
        self.hasBlendShapes = hasBlendShapes
        self.deviceModel = deviceModel
        self.hasAudio = hasAudio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        vertexCount = try container.decode(Int.self, forKey: .vertexCount)
        meshFrameCount = try container.decode(Int.self, forKey: .meshFrameCount)
        textureSize = try container.decode(Int.self, forKey: .textureSize)
        hasBlendShapes = try container.decode(Bool.self, forKey: .hasBlendShapes)
        deviceModel = try container.decode(String.self, forKey: .deviceModel)
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
    }

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
