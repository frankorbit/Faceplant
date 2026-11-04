import simd

extension FaceplantRenderer {
    /// 绕原点环绕的相机：yaw 绕 y 轴，pitch 绕 x 轴，弧度；distance 是到原点的距离
    struct OrbitCamera {
        var distance: Float
        var yaw: Float = 0
        var pitch: Float = 0

        static let yawLimit: Float = .pi * 0.45
        static let pitchLimit: Float = .pi * 0.35

        mutating func clamp(distanceRange: ClosedRange<Float>) {
            yaw = min(max(yaw, -Self.yawLimit), Self.yawLimit)
            pitch = min(max(pitch, -Self.pitchLimit), Self.pitchLimit)
            distance = min(max(distance, distanceRange.lowerBound), distanceRange.upperBound)
        }

        /// 相机位置：把 (0, 0, distance) 先绕 x 转 pitch，再绕 y 转 yaw
        var position: SIMD3<Float> {
            SIMD3<Float>(
                distance * sin(yaw) * cos(pitch),
                distance * sin(pitch),
                distance * cos(yaw) * cos(pitch)
            )
        }

        /// 看向原点的 view 矩阵，右手系，相机看 -z
        var viewMatrix: simd_float4x4 {
            let eye = position
            let forward = simd_normalize(-eye)
            var up = SIMD3<Float>(0, 1, 0)
            if abs(simd_dot(forward, up)) > 0.999 { up = SIMD3<Float>(0, 0, -1) }
            let right = simd_normalize(simd_cross(forward, up))
            let trueUp = simd_cross(right, forward)
            return simd_float4x4(columns: (
                SIMD4<Float>(right.x, trueUp.x, -forward.x, 0),
                SIMD4<Float>(right.y, trueUp.y, -forward.y, 0),
                SIMD4<Float>(right.z, trueUp.z, -forward.z, 0),
                SIMD4<Float>(-simd_dot(right, eye), -simd_dot(trueUp, eye), simd_dot(forward, eye), 1)
            ))
        }
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / max(aspect, 1e-4)
        let zRange = far - near
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zRange, -1),
            SIMD4<Float>(0, 0, -2 * far * near / zRange, 0)
        ))
    }
}
