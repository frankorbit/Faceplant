import Foundation
import simd

/// 给脸网格加一圈平滑的鼓包，把悬在墙面上方的外轮廓接到墙面上。
///
/// ARKit 的网格是一张开口薄壳，边缘在墙面上方；原版的效果像一张橡皮墙被后面的脸顶起来，
/// 脸四周到墙面是一个平滑的鼓包，墙纹沿着鼓包弯过去。这里为外轮廓上的每个顶点向外生成 `ringCount` 圈顶点：
/// 第 t 圈（t 从 0 到 1）沿远离脸中心的方向外推 width × t，高度按 (1 − t)² 从轮廓高度衰减到 0，
/// 宽度 width = 轮廓高度 × slope。相邻圈之间连成四边形带。
///
/// 鼓包顶点复用对应轮廓顶点的 UV，`rim` 取负值，脸 pass 里遮罩为零，只显示拉伸后的墙纹。
struct FaceSkirt {
    static let ringCount = 6

    /// 输入顶点数，`extend` 的输入必须是这个长度
    let baseVertexCount: Int
    /// 外轮廓环
    let loop: [Int]
    /// 加鼓包后的拓扑：第 k 圈（k 从 1 起）第 i 个顶点的索引 = baseVertexCount + (k − 1) × loop.count + i
    let topology: FaceMeshTopology
    /// 鼓包顶点的轮廓距离，负值，和拓扑一起静态
    let rims: [Float]

    /// 渲染时顶点 z 会变成 z' = z · depthScale + depthOffset，鼓包底部要落在 z' = 0 上
    struct Shape {
        var faceCenter: SIMD2<Float>
        var depthScale: Float
        var depthOffset: Float
        /// 鼓包宽度与轮廓高度之比
        var slope: Float
    }

    init(base: FaceMeshTopology) {
        baseVertexCount = base.vertexCount
        loop = FaceMeshCapping.outerLoop(in: base.triangleIndices) ?? []
        let loopCount = loop.count

        var uvs = base.textureCoordinates
        var indices = base.triangleIndices
        var rims = [Float]()
        for ring in 1 ... Self.ringCount {
            let fraction = Float(ring) / Float(Self.ringCount)
            for (position, vertex) in loop.enumerated() {
                uvs.append(base.textureCoordinates[vertex])
                rims.append(-fraction)
                let nextPosition = (position + 1) % loopCount
                // 上一圈（ring == 1 时是轮廓本身）到本圈的四边形带
                let innerA = ring == 1 ? Int16(vertex) : Int16(base.vertexCount + (ring - 2) * loopCount + position)
                let innerB = ring == 1 ? Int16(loop[nextPosition]) : Int16(base.vertexCount + (ring - 2) * loopCount + nextPosition)
                let outerA = Int16(base.vertexCount + (ring - 1) * loopCount + position)
                let outerB = Int16(base.vertexCount + (ring - 1) * loopCount + nextPosition)
                indices += [innerA, outerA, innerB, innerB, outerA, outerB]
            }
        }
        if loopCount == 0 {
            rims = []
        }
        topology = FaceMeshTopology(vertexCount: uvs.count, textureCoordinates: uvs, triangleIndices: indices)
        self.rims = rims
    }

    /// 在输入顶点后追加鼓包顶点。长度不符原样返回。
    func extend(_ vertices: [SIMD3<Float>], shape: Shape) -> [SIMD3<Float>] {
        guard vertices.count == baseVertexCount, !loop.isEmpty else { return vertices }
        let scale = abs(shape.depthScale) > 1e-5 ? shape.depthScale : 1

        var result = vertices
        result.reserveCapacity(vertices.count + loop.count * Self.ringCount)
        for ring in 1 ... Self.ringCount {
            let fraction = Float(ring) / Float(Self.ringCount)
            // 二次衰减：从轮廓就开始往下落，落到墙面时切线水平。余弦在轮廓处有一段平台，看起来像先鼓出去一个包再掉下来
            let heightFactor = (1 - fraction) * (1 - fraction)
            for vertex in loop {
                let point = vertices[vertex]
                let height = max(point.z * scale + shape.depthOffset, 0)
                let radial = SIMD2<Float>(point.x, point.y) - shape.faceCenter
                let length = simd_length(radial)
                let outward = length > 1e-5 ? radial / length : SIMD2<Float>(0, 0)
                let foot = SIMD2<Float>(point.x, point.y) + outward * height * shape.slope * fraction
                // 反算回 shader 变换前的 z
                let targetZ = height * heightFactor
                result.append(SIMD3<Float>(foot.x, foot.y, (targetZ - shape.depthOffset) / scale))
            }
        }
        return result
    }
}
