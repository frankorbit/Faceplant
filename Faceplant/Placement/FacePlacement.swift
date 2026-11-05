import ARKit
import simd

/// 把 raycast 命中结果变成脸的世界变换：+z 对准表面法线并朝向相机，+y 是脸的上方。
enum FacePlacement {
    /// 世界上方在表面上的投影短于这个长度（即法线与竖直方向夹角小于约 12°）时按水平面处理
    private static let horizontalThreshold: Float = 0.2

    /// - Parameters:
    ///   - hit: `ARSession.raycast` 的结果，`worldTransform` 的 +y 是表面法线
    ///   - cameraTransform: 当前 `ARCamera.transform`，用来判断法线朝向与水平面上的"上"
    static func faceTransform(hit: ARRaycastResult, cameraTransform: simd_float4x4) -> simd_float4x4 {
        let position = hit.worldTransform.position
        let cameraPosition = cameraTransform.position

        var forward = simd_normalize(hit.worldTransform.columns.1.xyz)
        // 法线要指向相机这一侧，否则脸会长进墙里
        if simd_dot(forward, cameraPosition - position) < 0 {
            forward = -forward
        }

        // 竖直面：脸的上方就是世界上方。
        // 水平面（桌面、地板）：世界上方与法线平行没法用，改用屏幕上方在面上的投影，用户此刻怎么拿手机，脸就朝哪边正。
        // 之前用"相机到落点的水平方向"，低头俯视时这个向量几乎为零，方向由噪声决定，脸的朝向看起来随机。
        var up = project(SIMD3<Float>(0, 1, 0), ontoPlaneWithNormal: forward)
        if simd_length(up) < horizontalThreshold {
            up = project(screenUp(cameraTransform: cameraTransform), ontoPlaneWithNormal: forward)
        }
        if simd_length(up) < 1e-4 {
            up = project(abs(forward.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1), ontoPlaneWithNormal: forward)
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

    /// 手指从 `from` 拖到 `to`，脸在自己所在的平面上应该挪多少，结果是脸局部 xy（米）。
    /// 两个点都沿视线投到脸所在的平面上再相减，所以拖动不会把脸拽离墙面；射线打不到平面时返回 nil。
    static func dragDelta(
        from: CGPoint, to: CGPoint, faceTransform: simd_float4x4, camera: ARCamera, viewSize: CGSize
    ) -> SIMD2<Float>? {
        let plane = facePlane(faceTransform)
        guard let start = camera.unprojectPoint(from, ontoPlane: plane, orientation: .portrait, viewportSize: viewSize),
              let end = camera.unprojectPoint(to, ontoPlane: plane, orientation: .portrait, viewportSize: viewSize)
        else { return nil }
        let delta = end - start
        return SIMD2<Float>(
            simd_dot(delta, simd_normalize(faceTransform.columns.0.xyz)),
            simd_dot(delta, simd_normalize(faceTransform.columns.1.xyz))
        )
    }

    /// `unprojectPoint(_:ontoPlane:)` 约定平面的局部 y 是法线，而脸的法线是 z，这里换一下轴，仍是右手系
    private static func facePlane(_ face: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(face.columns.0, face.columns.2, -face.columns.1, face.columns.3)
    }

    /// 竖屏下屏幕上方在世界里的方向：ARKit 相机坐标以横屏（home 键在右）为准，+x 指向 home 键，竖屏时 +x 朝下
    private static func screenUp(cameraTransform: simd_float4x4) -> SIMD3<Float> {
        -cameraTransform.columns.0.xyz
    }

    private static func project(_ vector: SIMD3<Float>, ontoPlaneWithNormal normal: SIMD3<Float>) -> SIMD3<Float> {
        vector - simd_dot(vector, normal) * normal
    }
}
