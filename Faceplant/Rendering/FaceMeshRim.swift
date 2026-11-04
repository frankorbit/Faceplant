import Foundation
import simd

/// 每个顶点到网格外轮廓的测地距离（米），用来沿真实轮廓做等宽的淡出带。
///
/// 包围盒椭圆在额角、下颌这些地方和轮廓差得远，淡出带会一边宽一边窄；
/// 测地距离按静止姿态算一次即可，表情变化对它的影响可以忽略。
enum FaceMeshRim {
    /// 从外轮廓环出发的多源 Dijkstra。顶点数一千出头，直接用数组扫最小值就够了。
    static func distances(vertices: [SIMD3<Float>], triangleIndices: [Int16], outerLoop: [Int]) -> [Float] {
        let count = vertices.count
        var neighbors = [[Int]](repeating: [], count: count)
        for base in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let corners = [Int(triangleIndices[base]), Int(triangleIndices[base + 1]), Int(triangleIndices[base + 2])]
            for corner in 0 ..< 3 {
                let from = corners[corner]
                let to = corners[(corner + 1) % 3]
                guard from < count, to < count else { continue }
                neighbors[from].append(to)
                neighbors[to].append(from)
            }
        }

        var distance = [Float](repeating: .greatestFiniteMagnitude, count: count)
        var settled = [Bool](repeating: false, count: count)
        for vertex in outerLoop where vertex < count {
            distance[vertex] = 0
        }

        for _ in 0 ..< count {
            var current = -1
            var best = Float.greatestFiniteMagnitude
            for index in 0 ..< count where !settled[index] && distance[index] < best {
                best = distance[index]
                current = index
            }
            guard current >= 0 else { break }
            settled[current] = true
            for neighbor in neighbors[current] where !settled[neighbor] {
                let candidate = best + simd_distance(vertices[current], vertices[neighbor])
                if candidate < distance[neighbor] {
                    distance[neighbor] = candidate
                }
            }
        }
        // 孤立顶点视为脸内部
        return distance.map { $0 == .greatestFiniteMagnitude ? 1 : $0 }
    }
}
