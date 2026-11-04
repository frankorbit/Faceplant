import Foundation
import SceneKit
import simd

/// 把 FaceMeshTopology 与一帧顶点组装成 SCNGeometry。UV 源与索引元素按拓扑缓存，每帧只重建顶点源。
///
/// 录制页预览与 Review 回放共用，保证两边看到的网格（含加盖）一致。
struct SceneKitFaceGeometry {
    let topology: FaceMeshTopology
    private let uvSource: SCNGeometrySource
    private let element: SCNGeometryElement

    init(topology: FaceMeshTopology) {
        self.topology = topology
        let uvData = topology.textureCoordinates.withUnsafeBufferPointer { Data(buffer: $0) }
        uvSource = SCNGeometrySource(
            data: uvData,
            semantic: .texcoord,
            vectorCount: topology.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        element = SCNGeometryElement(indices: topology.triangleIndices, primitiveType: .triangles)
    }

    /// 顶点数与拓扑不符返回 nil，调用方沿用上一帧几何
    func makeGeometry(vertices: [SIMD3<Float>], material: SCNMaterial) -> SCNGeometry? {
        guard vertices.count == topology.vertexCount else { return nil }
        let vertexData = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let geometry = SCNGeometry(sources: [vertexSource, uvSource], elements: [element])
        geometry.materials = [material]
        return geometry
    }
}
