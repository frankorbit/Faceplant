import Foundation

/// 录制包二进制格式的读写辅助。所有数值按小端、平台原生布局写入；项目只跑在 arm64 上，不做字节序转换。
extension Data {
    mutating func appendValue(_ value: some Any) {
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }

    mutating func appendArray(_ array: [some Any]) {
        array.withUnsafeBufferPointer { append(Data(buffer: $0)) }
    }

    /// 不要求对齐，调用方保证 offset + size 在范围内
    func loadValue<T>(at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    func loadArray<T>(at offset: Int, count: Int) -> [T] {
        withUnsafeBytes { raw in
            (0 ..< count).map { raw.loadUnaligned(fromByteOffset: offset + $0 * MemoryLayout<T>.stride, as: T.self) }
        }
    }
}
