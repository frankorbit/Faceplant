import Foundation
import simd

/// 给 ARKit canonical face mesh 的眼睛与嘴洞口加盖，得到一个封闭的面具。
///
/// 洞口通过"只属于一个三角形的边"找出来：串成环后最长的一环是脸的外轮廓，其余的是左眼、右眼、嘴。
/// 每个洞在中心加一个顶点做扇形三角化，中心顶点的位置与 UV 都是环上顶点的平均值，所以每帧随表情一起动。
/// 加盖后的三角形和原网格一起进烘焙 pass，UV 空间里洞的位置本来就是空的，盖子正好填进去；
/// 张嘴时舌头、牙就贴在盖子上，与原版表现一致。
///
/// 录制包里的 topology.bin 与 mesh.bin 始终存 ARKit 原始数据，加盖只发生在内存里。
struct FaceMeshCapping {
    /// ARKit 原始拓扑，录制包写这个
    let base: FaceMeshTopology
    /// 原始顶点数，`extend` 的输入必须是这个长度
    let baseVertexCount: Int
    /// 每个洞口的环，按原网格的绕向排序；盖子中心顶点的索引 = baseVertexCount + 环的序号
    let loops: [[Int]]
    /// 加盖后的拓扑：原 UV 加各环中心 UV，原索引加各环的扇形索引
    let topology: FaceMeshTopology

    init(base: FaceMeshTopology) {
        self.base = base
        baseVertexCount = base.vertexCount
        loops = Self.holeLoops(in: base.triangleIndices)

        var uvs = base.textureCoordinates
        var indices = base.triangleIndices
        for (loopIndex, loop) in loops.enumerated() {
            let center = base.vertexCount + loopIndex
            uvs.append(Self.average(loop.map { base.textureCoordinates[$0] }))
            // 相邻三角形共享边的方向相反：原网格沿 a→b 走过这条边，盖子就走 b→a
            for (position, from) in loop.enumerated() {
                let to = loop[(position + 1) % loop.count]
                indices.append(Int16(center))
                indices.append(Int16(to))
                indices.append(Int16(from))
            }
        }
        topology = FaceMeshTopology(vertexCount: uvs.count, textureCoordinates: uvs, triangleIndices: indices)
    }

    /// 在原始顶点后追加各洞口的中心顶点。长度不符视为数据损坏，原样返回让渲染层按旧拓扑处理。
    func extend(_ vertices: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard vertices.count == baseVertexCount else { return vertices }
        var result = vertices
        result.reserveCapacity(vertices.count + loops.count)
        for loop in loops {
            result.append(Self.average(loop.map { vertices[$0] }))
        }
        return result
    }

    func extend(_ frame: FaceMeshFrame) -> FaceMeshFrame {
        var extended = frame
        extended.vertices = extend(frame.vertices)
        return extended
    }

    // MARK: - 边界环

    /// 返回除外轮廓外的所有边界环。环上顶点按原网格三角形的方向排列（a→b 是某个三角形的一条有向边）。
    static func holeLoops(in triangleIndices: [Int16]) -> [[Int]] {
        var directedCount = [DirectedEdge: Int]()
        var undirectedCount = [UndirectedEdge: Int]()
        for base in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let corners = [Int(triangleIndices[base]), Int(triangleIndices[base + 1]), Int(triangleIndices[base + 2])]
            for corner in 0 ..< 3 {
                let from = corners[corner]
                let to = corners[(corner + 1) % 3]
                directedCount[DirectedEdge(from: from, to: to), default: 0] += 1
                undirectedCount[UndirectedEdge(from, to), default: 0] += 1
            }
        }

        // 边界边只被一个三角形使用；按它在该三角形里的方向建 from → to 映射
        var next = [Int: Int]()
        for (edge, _) in directedCount where undirectedCount[UndirectedEdge(edge.from, edge.to)] == 1 {
            next[edge.from] = edge.to
        }

        var loops = [[Int]]()
        var visited = Set<Int>()
        for start in next.keys.sorted() where !visited.contains(start) {
            var loop = [Int]()
            var current = start
            while !visited.contains(current), let following = next[current] {
                visited.insert(current)
                loop.append(current)
                current = following
            }
            // 没回到起点说明边界不是流形，这段不加盖
            if current == start, loop.count >= 3 {
                loops.append(loop)
            }
        }

        // 最长的一环是脸的外轮廓，不加盖
        guard let outerIndex = loops.indices.max(by: { loops[$0].count < loops[$1].count }) else { return [] }
        loops.remove(at: outerIndex)
        return loops
    }

    private struct DirectedEdge: Hashable {
        let from: Int
        let to: Int
    }

    private struct UndirectedEdge: Hashable {
        let low: Int
        let high: Int

        init(_ first: Int, _ second: Int) {
            low = min(first, second)
            high = max(first, second)
        }
    }

    private static func average(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !values.isEmpty else { return .zero }
        return values.reduce(.zero, +) / Float(values.count)
    }

    private static func average(_ values: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !values.isEmpty else { return .zero }
        return values.reduce(.zero, +) / Float(values.count)
    }
}
