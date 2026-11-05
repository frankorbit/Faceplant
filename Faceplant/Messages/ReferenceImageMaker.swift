import ARKit
import CoreImage
import simd
import UIKit

/// 从放置那一刻的相机帧里裁出一块墙面当参考图，并估出它的物理尺寸和在世界里的位置。
///
/// 世界地图重定位依赖光照和特征点分布，换个时间段可能对不上；参考图识别对光照更宽容，两者互为备份。
/// 裁的是以脸为中心、短边 60% 的正方形：脸是虚拟的，重访时这块墙还在原处。
enum ReferenceImageMaker {
    struct Output {
        /// 竖直正立的参考图
        let image: UIImage
        /// 参考图的物理宽度（米）
        let physicalWidth: Float
        /// 重访时 ARImageAnchor 应有的世界变换：原点在图中心，+y 是墙面法线，+x 是图的右方
        let imageTransform: simd_float4x4
    }

    /// 图像短边的多少做裁剪边长
    private static let cropFraction: CGFloat = 0.6

    static func make(frame: ARFrame, faceTransform: simd_float4x4) throws -> Output {
        let camera = frame.camera
        let resolution = camera.imageResolution
        let facePosition = SIMD3<Float>(faceTransform.columns.3.x, faceTransform.columns.3.y, faceTransform.columns.3.z)

        // 脸在传感器原始方向（横屏，home 键在右）图像里的像素位置
        let projected = camera.projectPoint(facePosition, orientation: .landscapeRight, viewportSize: resolution)
        let side = min(resolution.width, resolution.height) * cropFraction
        let center = CGPoint(
            x: min(max(projected.x, side / 2), resolution.width - side / 2),
            y: min(max(projected.y, side / 2), resolution.height - side / 2)
        )

        // 物理宽度：像素宽 × 深度 / 焦距，墙面近似垂直于光轴
        let cameraSpace = simd_inverse(camera.transform) * SIMD4<Float>(facePosition, 1)
        let depth = abs(cameraSpace.z)
        let focal = camera.intrinsics.columns.0.x
        guard depth > 0.05, focal > 1 else {
            throw FaceplantError.messageSaveFailed("放置点离相机太近，做不出参考图")
        }
        let physicalWidth = Float(side) * depth / focal

        let imageTransform = try makeImageTransform(
            camera: camera,
            faceTransform: faceTransform,
            cropCenter: center,
            resolution: resolution
        )
        let image = try cropUpright(pixelBuffer: frame.capturedImage, center: center, side: side)
        return Output(image: image, physicalWidth: physicalWidth, imageTransform: imageTransform)
    }

    /// 裁剪中心在墙面上的三维位置，加上图的朝向，拼成 ARImageAnchor 约定的变换（图躺在 x-z 平面，+y 为法线）
    private static func makeImageTransform(
        camera: ARCamera, faceTransform: simd_float4x4, cropCenter: CGPoint, resolution: CGSize
    ) throws -> simd_float4x4 {
        let right = SIMD3<Float>(faceTransform.columns.0.x, faceTransform.columns.0.y, faceTransform.columns.0.z)
        let up = SIMD3<Float>(faceTransform.columns.1.x, faceTransform.columns.1.y, faceTransform.columns.1.z)
        let normal = SIMD3<Float>(faceTransform.columns.2.x, faceTransform.columns.2.y, faceTransform.columns.2.z)
        // unprojectPoint 要的平面约定和 ARPlaneAnchor 一样：局部 x-z 是平面，+y 是法线
        let wallPlane = simd_float4x4(
            SIMD4<Float>(right, 0), SIMD4<Float>(normal, 0), SIMD4<Float>(-up, 0), faceTransform.columns.3
        )
        guard let imageCenter = camera.unprojectPoint(
            cropCenter, ontoPlane: wallPlane, orientation: .landscapeRight, viewportSize: resolution
        ) else {
            throw FaceplantError.messageSaveFailed("裁剪中心投不到墙面上")
        }

        // 竖屏正立的图，右方是相机坐标的 +y（横屏传感器的上方），投影到墙面
        let cameraY = SIMD3<Float>(camera.transform.columns.1.x, camera.transform.columns.1.y, camera.transform.columns.1.z)
        var xAxis = cameraY - simd_dot(cameraY, normal) * normal
        if simd_length(xAxis) < 1e-3 {
            xAxis = right
        }
        xAxis = simd_normalize(xAxis)
        let zAxis = simd_normalize(simd_cross(xAxis, normal))
        return simd_float4x4(
            SIMD4<Float>(xAxis, 0), SIMD4<Float>(normal, 0), SIMD4<Float>(zAxis, 0), SIMD4<Float>(imageCenter, 1)
        )
    }

    /// 从 YCbCr 相机帧裁出正方形并转成竖屏正立的 RGB 图
    private static func cropUpright(pixelBuffer: CVPixelBuffer, center: CGPoint, side: CGFloat) throws -> UIImage {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        // Core Image 原点在左下，像素坐标 y 向下，要翻一次
        let cropRect = CGRect(
            x: center.x - side / 2, y: source.extent.height - center.y - side / 2, width: side, height: side
        ).integral
        guard let cropped = CIContext().createCGImage(source, from: cropRect) else {
            throw FaceplantError.messageSaveFailed("裁剪参考图失败")
        }
        // 传感器图是横屏，顺时针转 90° 得到竖屏正立；画一遍让 cgImage 本身就是正的
        let rotated = UIImage(cgImage: cropped, scale: 1, orientation: .right)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: cropRect.height, height: cropRect.width)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            rotated.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
