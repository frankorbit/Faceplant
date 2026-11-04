import simd

extension simd_float4x4 {
    /// 列主序展开成 16 个 Float，用于写入二进制流。
    var flattened: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    /// `flattened` 的逆操作；长度不是 16 返回 nil，交给调用方按数据损坏处理。
    init?(flattened: [Float]) {
        guard flattened.count == 16 else { return nil }
        self.init(
            SIMD4<Float>(flattened[0], flattened[1], flattened[2], flattened[3]),
            SIMD4<Float>(flattened[4], flattened[5], flattened[6], flattened[7]),
            SIMD4<Float>(flattened[8], flattened[9], flattened[10], flattened[11]),
            SIMD4<Float>(flattened[12], flattened[13], flattened[14], flattened[15])
        )
    }
}
