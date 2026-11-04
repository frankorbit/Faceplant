import ARKit
import simd

/// 把 raycast 命中结果变成脸的世界变换：+z 对准表面法线并朝向相机，+y 尽量朝上。
enum FacePlacement {
    /// - Parameters:
    ///   - hit: `ARSession.raycast` 的结果，`worldTransform` 的 +y 是表面法线
    ///   - cameraTransform: 当前 `ARCamera.transform`，用来判断法线朝向与水平面上的"上"
    static func faceTransform(hit: ARRaycastResult, cameraTransform: simd_float4x4) -> simd_float4x4 {
        let position = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        var forward = simd_normalize(SIMD3<Float>(
            hit.worldTransform.columns.1.x,
            hit.worldTransform.columns.1.y,
            hit.worldTransform.columns.1.z
        ))
        // 法线要指向相机这一侧，否则脸会长进墙里
        if simd_dot(forward, cameraPosition - position) < 0 {
            forward = -forward
        }

        let worldUp = SIMD3<Float>(0, 1, 0)
        var up = worldUp - simd_dot(worldUp, forward) * forward
        if simd_length(up) < 0.1 {
            // 水平表面：世界上方与法线平行，改用"远离观察者"的方向做脸的上方，站在近侧低头看脸是正的
            let away = position - cameraPosition
            up = away - simd_dot(away, forward) * forward
        }
        if simd_length(up) < 1e-4 {
            up = SIMD3<Float>(0, 0, 1)
        }
        up = simd_normalize(up)
        let right = simd_normalize(simd_cross(up, forward))

        return simd_float4x4(
            SIMD4<Float>(right, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(forward, 0),
            SIMD4<Float>(position, 1)
        )
    }

    /// 屏幕点击位置换算成 capturedImage 归一化坐标，供 `ARFrame.raycastQuery` 使用
    static func imagePoint(fromViewPoint point: CGPoint, viewSize: CGSize, frame: ARFrame) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let normalized = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        let display = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        return normalized.applying(display.inverted())
    }
}
