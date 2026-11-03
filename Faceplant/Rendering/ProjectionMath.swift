import ARKit
import simd
import UIKit

/// 把 ARKit 的相机参数整理成烘焙 pass 需要的 uniform。
enum ProjectionMath {
    /// - Parameters:
    ///   - viewportSize: 必须与真正渲染 AR 画面的视图尺寸一致，三处（投影矩阵、displayTransform、渲染）用同一组值。
    static func bakeUniforms(
        frame: ARFrame,
        anchorTransform: simd_float4x4,
        orientation: UIInterfaceOrientation,
        viewportSize: CGSize,
        flipV: Bool
    ) -> BakeUniforms {
        let camera = frame.camera
        let projection = camera.projectionMatrix(for: orientation, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)
        let view = camera.viewMatrix(for: orientation)
        // displayTransform 把图像归一化坐标映射到视口归一化坐标，这里需要反向
        let display = frame.displayTransform(for: orientation, viewportSize: viewportSize).inverted()
        return BakeUniforms(
            projectionViewModel: projection * view * anchorTransform,
            displayTransformInverse: float3x3(display),
            flipV: flipV ? 1 : 0
        )
    }

    /// CGAffineTransform 是行向量约定 (x, y, 1) · M，转成列主序 3x3 后可直接 M · float3(x, y, 1)。
    static func float3x3(_ transform: CGAffineTransform) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(transform.a), Float(transform.b), 0),
            SIMD3<Float>(Float(transform.c), Float(transform.d), 0),
            SIMD3<Float>(Float(transform.tx), Float(transform.ty), 1)
        ))
    }
}
