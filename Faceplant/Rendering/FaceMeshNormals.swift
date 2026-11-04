import Foundation
import simd

/// 按面累加再归一化的顶点法线。1223 个顶点、2400 多个三角形在 CPU 上每帧只要几十微秒，不值得上 compute kernel。
enum FaceMeshNormals {
    static func compute(vertices: [SIMD3<Float>], triangleIndices: [Int16]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for base in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let ia = Int(triangleIndices[base])
            let ib = Int(triangleIndices[base + 1])
            let ic = Int(triangleIndices[base + 2])
            guard ia < vertices.count, ib < vertices.count, ic < vertices.count else { continue }
            // 不归一化面法线，大三角形自然权重更高
            let faceNormal = simd_cross(vertices[ib] - vertices[ia], vertices[ic] - vertices[ia])
            normals[ia] += faceNormal
            normals[ib] += faceNormal
            normals[ic] += faceNormal
        }
        return normals.map { normal in
            let length = simd_length(normal)
            // 退化顶点给一个朝前的法线，避免 shader 里 normalize(0)
            return length > 0 ? normal / length : SIMD3<Float>(0, 0, 1)
        }
    }
}
