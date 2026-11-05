import simd

/// 用户用手势在 anchor 基础上对脸做的微调，全部在 anchor 局部坐标里：
/// 沿墙面平移（xy，米）、绕墙面法线旋转（z，弧度）、整体缩放。
///
/// anchor 本身停在用户点击的落点不动，这样世界地图里存的还是落点，重访时把同一份调整叠上去即可；
/// 合成顺序是先缩放、再旋转、最后平移，旋转与缩放都以脸的局部原点为中心。
struct FaceAdjustment: Equatable {
    static let scaleRange: ClosedRange<Float> = 0.3 ... 3

    var translation = SIMD2<Float>(repeating: 0)
    var rotation: Float = 0
    var scale: Float = 1

    static let identity = FaceAdjustment()

    /// 不含缩放的部分，参考图裁剪等只关心脸在哪、朝哪的地方用它
    var rigidTransform: simd_float4x4 {
        .translation(SIMD3<Float>(translation, 0)) * .rotationAboutZ(rotation)
    }

    /// 渲染用的完整局部矩阵
    var transform: simd_float4x4 {
        rigidTransform * .uniformScale(scale)
    }
}
