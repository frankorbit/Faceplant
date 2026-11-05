import simd

extension simd_float4x4 {
    /// 平移矩阵
    static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(offset, 1)
        return matrix
    }

    /// 绕 +z 轴旋转，弧度，右手系下从 +z 看逆时针为正
    static func rotationAboutZ(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(cosine, sine, 0, 0),
            SIMD4<Float>(-sine, cosine, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func uniformScale(_ scale: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4<Float>(scale, scale, scale, 1))
    }

    var position: SIMD3<Float> { columns.3.xyz }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
