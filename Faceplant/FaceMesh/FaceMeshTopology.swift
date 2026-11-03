import ARKit
import simd

/// ARKit canonical face mesh 中不随帧变化的部分：索引与展开 UV。
/// 启动后从第一个 ARFaceGeometry 取一次即可，之后每帧只需上传顶点。
struct FaceMeshTopology {
    let vertexCount: Int
    let textureCoordinates: [SIMD2<Float>]
    let triangleIndices: [Int16]

    var indexCount: Int { triangleIndices.count }

    init(geometry: ARFaceGeometry) {
        vertexCount = geometry.vertices.count
        textureCoordinates = Array(geometry.textureCoordinates)
        triangleIndices = Array(geometry.triangleIndices)
    }
}
