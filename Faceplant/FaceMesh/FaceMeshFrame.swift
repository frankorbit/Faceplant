import ARKit
import simd

/// 左右眼球在 face 局部坐标下的刚体变换，来自 `ARFaceAnchor.leftEyeTransform` / `rightEyeTransform`。
///
/// 原点是眼球中心，+z 为视线方向。ARKit 标准网格在眼睛处是空洞，假眼球靠这两个变换摆到洞后面并跟随视线转动。
struct EyePose: Equatable {
    var left: simd_float4x4
    var right: simd_float4x4

    init(left: simd_float4x4, right: simd_float4x4) {
        self.left = left
        self.right = right
    }

    init(anchor: ARFaceAnchor) {
        self.init(left: anchor.leftEyeTransform, right: anchor.rightEyeTransform)
    }

    /// 平移线性插值，旋转 slerp。眼球变换没有缩放，所以可以安全地从矩阵里取四元数。
    static func interpolate(_ from: EyePose, _ to: EyePose, fraction: Float) -> EyePose {
        EyePose(
            left: interpolate(from.left, to.left, fraction: fraction),
            right: interpolate(from.right, to.right, fraction: fraction)
        )
    }

    private static func interpolate(_ from: simd_float4x4, _ to: simd_float4x4, fraction: Float) -> simd_float4x4 {
        let rotation = simd_slerp(simd_quatf(from), simd_quatf(to), fraction)
        var result = simd_float4x4(rotation)
        result.columns.3 = simd_mix(from.columns.3, to.columns.3, SIMD4<Float>(repeating: fraction))
        return result
    }
}

/// 一帧人脸网格。顶点在 face 局部坐标，单位米。
struct FaceMeshFrame {
    /// 实时模式下是 ARFrame.timestamp；录制包里是相对录制起点的秒数
    var timestamp: TimeInterval
    var vertices: [SIMD3<Float>]
    /// 顺序见 BlendShapeOrder，长度固定为 BlendShapeOrder.count
    var blendShapes: [Float]?
    /// 旧录制包没有这项，为 nil 时渲染层不画眼球
    var eyes: EyePose?

    init(timestamp: TimeInterval, vertices: [SIMD3<Float>], blendShapes: [Float]?, eyes: EyePose? = nil) {
        self.timestamp = timestamp
        self.vertices = vertices
        self.blendShapes = blendShapes
        self.eyes = eyes
    }

    init(anchor: ARFaceAnchor, timestamp: TimeInterval) {
        self.init(
            timestamp: timestamp,
            vertices: Array(anchor.geometry.vertices),
            blendShapes: BlendShapeOrder.vector(from: anchor.blendShapes),
            eyes: EyePose(anchor: anchor)
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
        let eyes: EyePose? = if let fromEyes = from.eyes, let toEyes = to.eyes {
            EyePose.interpolate(fromEyes, toEyes, fraction: clamped)
        } else {
            from.eyes ?? to.eyes
        }
        return FaceMeshFrame(
            timestamp: from.timestamp + (to.timestamp - from.timestamp) * TimeInterval(clamped),
            vertices: vertices,
            blendShapes: blendShapes,
            eyes: eyes
        )
    }
}
