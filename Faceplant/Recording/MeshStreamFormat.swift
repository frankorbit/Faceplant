import Foundation

/// mesh.bin 的布局常量，Writer 与 Reader 共用。
///
/// Header (32 bytes)
///   magic        UInt32   'FPMS'
///   version      UInt32   1
///   vertexCount  UInt32
///   frameCount   UInt32   录制结束时回填
///   flags        UInt32   bit0 = 顶点用 Float16，bit1 = 含 blendShapes，bit2 = 含左右眼球变换
///   reserved     12 bytes
/// Frame × frameCount
///   timestamp    Float64  相对录制起点的秒数
///   vertices     vertexCount × 3 × Float16
///   blendShapes  BlendShapeOrder.count × Float32（flags.bit1 时存在）
///   eyes         2 × 16 × Float32，左眼在前，列主序（flags.bit2 时存在）
///
/// 新字段只通过 flags 追加在帧尾，旧文件没有对应 bit 时直接跳过，不需要升版本。
enum MeshStreamFormat {
    static let magic: UInt32 = 0x534D_5046
    static let version: UInt32 = 1
    static let headerSize = 32
    static let frameCountOffset = 12
    /// 左右眼各一个 4x4 矩阵
    static let eyeFloatCount = 32

    struct Flags: OptionSet {
        let rawValue: UInt32
        static let halfFloatVertices = Flags(rawValue: 1 << 0)
        static let blendShapes = Flags(rawValue: 1 << 1)
        static let eyeTransforms = Flags(rawValue: 1 << 2)
    }

    static func frameByteCount(vertexCount: Int, flags: Flags) -> Int {
        var count = MemoryLayout<Float64>.size + vertexCount * 3 * MemoryLayout<Float16>.size
        if flags.contains(.blendShapes) {
            count += BlendShapeOrder.count * MemoryLayout<Float>.size
        }
        if flags.contains(.eyeTransforms) {
            count += eyeFloatCount * MemoryLayout<Float>.size
        }
        return count
    }
}
