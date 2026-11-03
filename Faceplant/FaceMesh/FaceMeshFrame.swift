import ARKit
import simd

/// 一帧人脸网格。顶点在 face 局部坐标，单位米。
struct FaceMeshFrame {
    /// 实时模式下是 ARFrame.timestamp；录制包里是相对录制起点的秒数
    var timestamp: TimeInterval
    var vertices: [SIMD3<Float>]
    /// 顺序见 BlendShapeOrder，长度固定为 BlendShapeOrder.count
    var blendShapes: [Float]?

    init(timestamp: TimeInterval, vertices: [SIMD3<Float>], blendShapes: [Float]?) {
        self.timestamp = timestamp
        self.vertices = vertices
        self.blendShapes = blendShapes
    }

    init(anchor: ARFaceAnchor, timestamp: TimeInterval) {
        self.init(
            timestamp: timestamp,
            vertices: Array(anchor.geometry.vertices),
            blendShapes: BlendShapeOrder.vector(from: anchor.blendShapes)
        )
    }

    /// 顶点与 blendShape 线性插值，t 取 [0, 1]。两帧顶点数不同视为数据损坏，直接返回前一帧。
    static func interpolate(_ from: FaceMeshFrame, _ to: FaceMeshFrame, fraction: Float) -> FaceMeshFrame {
        guard from.vertices.count == to.vertices.count else { return from }
        let clamped = min(max(fraction, 0), 1)
        let vertices = zip(from.vertices, to.vertices).map { simd_mix($0, $1, SIMD3<Float>(repeating: clamped)) }
        var blendShapes: [Float]?
        if let fromShapes = from.blendShapes, let toShapes = to.blendShapes, fromShapes.count == toShapes.count {
            blendShapes = zip(fromShapes, toShapes).map { $0 + ($1 - $0) * clamped }
        }
        return FaceMeshFrame(
            timestamp: from.timestamp + (to.timestamp - from.timestamp) * TimeInterval(clamped),
            vertices: vertices,
            blendShapes: blendShapes
        )
    }
}
