import Foundation
import simd

/// 单帧网格的二进制布局，mesh.bin 与附近通话链路共用。帧内布局见 `MeshStreamFormat`。
enum MeshFrameCodec {
    static func encode(_ frame: FaceMeshFrame, vertexCount: Int, flags: MeshStreamFormat.Flags) throws -> Data {
        guard frame.vertices.count == vertexCount else {
            throw FaceplantError.meshStreamCorrupted("顶点数 \(frame.vertices.count) 与拓扑 \(vertexCount) 不符")
        }
        var data = Data(capacity: MeshStreamFormat.frameByteCount(vertexCount: vertexCount, flags: flags))
        data.appendValue(frame.timestamp)

        var halves = [Float16]()
        halves.reserveCapacity(vertexCount * 3)
        for vertex in frame.vertices {
            halves.append(Float16(vertex.x))
            halves.append(Float16(vertex.y))
            halves.append(Float16(vertex.z))
        }
        data.appendArray(halves)

        if flags.contains(.blendShapes) {
            let blendShapes = frame.blendShapes ?? Array(repeating: 0, count: BlendShapeOrder.count)
            guard blendShapes.count == BlendShapeOrder.count else {
                throw FaceplantError.meshStreamCorrupted("blendShape 数量 \(blendShapes.count) 不符")
            }
            data.appendArray(blendShapes)
        }

        if flags.contains(.eyeTransforms) {
            // 没有眼球数据的帧写单位矩阵，读回后眼球会停在脸原点；采集路径总是带眼球，这只是兜底
            let eyes = frame.eyes ?? EyePose(left: matrix_identity_float4x4, right: matrix_identity_float4x4)
            data.appendArray(eyes.left.flattened + eyes.right.flattened)
        }
        return data
    }

    /// 从 `data` 的 `offset` 处解一帧。长度不够按损坏处理。
    static func decode(_ data: Data, at offset: Int, vertexCount: Int, flags: MeshStreamFormat.Flags) throws -> FaceMeshFrame {
        let frameSize = MeshStreamFormat.frameByteCount(vertexCount: vertexCount, flags: flags)
        guard offset >= 0, data.count - offset >= frameSize else {
            throw FaceplantError.meshStreamCorrupted("帧数据不完整")
        }
        var cursor = offset
        let timestamp: Float64 = data.loadValue(at: cursor)
        cursor += MemoryLayout<Float64>.size

        let halves: [Float16] = data.loadArray(at: cursor, count: vertexCount * 3)
        cursor += vertexCount * 3 * MemoryLayout<Float16>.size
        let vertices = stride(from: 0, to: halves.count, by: 3).map {
            SIMD3<Float>(Float(halves[$0]), Float(halves[$0 + 1]), Float(halves[$0 + 2]))
        }

        var blendShapes: [Float]?
        if flags.contains(.blendShapes) {
            blendShapes = data.loadArray(at: cursor, count: BlendShapeOrder.count)
            cursor += BlendShapeOrder.count * MemoryLayout<Float>.size
        }

        var eyes: EyePose?
        if flags.contains(.eyeTransforms) {
            let floats: [Float] = data.loadArray(at: cursor, count: MeshStreamFormat.eyeFloatCount)
            guard let left = simd_float4x4(flattened: Array(floats[0 ..< 16])),
                  let right = simd_float4x4(flattened: Array(floats[16 ..< 32]))
            else {
                throw FaceplantError.meshStreamCorrupted("眼球变换损坏")
            }
            eyes = EyePose(left: left, right: right)
        }
        return FaceMeshFrame(timestamp: timestamp, vertices: vertices, blendShapes: blendShapes, eyes: eyes)
    }
}
