import ARKit
import Foundation
import simd

/// ARKit canonical face mesh 中不随帧变化的部分：索引与展开 UV。
///
/// 实时模式从第一个 ARFaceGeometry 取一次；录制包里单独存一份 topology.bin，回放时不依赖 ARKit 会话。
struct FaceMeshTopology: Equatable {
    let vertexCount: Int
    let textureCoordinates: [SIMD2<Float>]
    let triangleIndices: [Int16]

    var indexCount: Int { triangleIndices.count }

    init(vertexCount: Int, textureCoordinates: [SIMD2<Float>], triangleIndices: [Int16]) {
        self.vertexCount = vertexCount
        self.textureCoordinates = textureCoordinates
        self.triangleIndices = triangleIndices
    }

    init(geometry: ARFaceGeometry) {
        self.init(
            vertexCount: geometry.vertices.count,
            textureCoordinates: Array(geometry.textureCoordinates),
            triangleIndices: Array(geometry.triangleIndices)
        )
    }

    // MARK: - 序列化

    // 文件布局（小端）：
    //   magic 'FPTP' UInt32 · version UInt32 · vertexCount UInt32 · indexCount UInt32
    //   uv Float32 × 2 × vertexCount
    //   indices Int16 × indexCount
    private static let magic: UInt32 = 0x5054_5046
    private static let version: UInt32 = 1
    private static let headerSize = 16

    func write(to url: URL) throws {
        var data = Data()
        data.appendValue(Self.magic)
        data.appendValue(Self.version)
        data.appendValue(UInt32(vertexCount))
        data.appendValue(UInt32(indexCount))
        data.appendArray(textureCoordinates.flatMap { [$0.x, $0.y] })
        data.appendArray(triangleIndices)
        try data.write(to: url, options: .atomic)
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= Self.headerSize else {
            throw FaceplantError.recordingPackageInvalid("topology.bin 太短")
        }
        let magic: UInt32 = data.loadValue(at: 0)
        let version: UInt32 = data.loadValue(at: 4)
        guard magic == Self.magic, version == Self.version else {
            throw FaceplantError.recordingPackageInvalid("topology.bin 魔数或版本不匹配")
        }
        let vertexCount = Int(data.loadValue(at: 8) as UInt32)
        let indexCount = Int(data.loadValue(at: 12) as UInt32)
        let uvBytes = vertexCount * 2 * MemoryLayout<Float>.size
        let indexBytes = indexCount * MemoryLayout<Int16>.size
        guard data.count == Self.headerSize + uvBytes + indexBytes else {
            throw FaceplantError.recordingPackageInvalid("topology.bin 长度与头部不符")
        }
        let uvs: [Float] = data.loadArray(at: Self.headerSize, count: vertexCount * 2)
        let indices: [Int16] = data.loadArray(at: Self.headerSize + uvBytes, count: indexCount)
        self.init(
            vertexCount: vertexCount,
            textureCoordinates: stride(from: 0, to: uvs.count, by: 2).map { SIMD2<Float>(uvs[$0], uvs[$0 + 1]) },
            triangleIndices: indices
        )
    }
}
