import Foundation

/// 顺序读二进制消息，越界按数据损坏抛错。配合 `Data+Binary` 的 append 系列使用。
struct BinaryReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    /// 读一个平凡类型（整数、浮点、C 结构体），不要求对齐
    mutating func read<T>(_: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw FaceplantError.callMessageCorrupted("读 \(T.self) 时数据不足") }
        let value: T = data.loadValue(at: offset)
        offset += size
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw FaceplantError.callMessageCorrupted("读 \(count) 字节时数据不足") }
        let start = data.startIndex + offset
        let slice = Data(data[start ..< start + count])
        offset += count
        return slice
    }

    /// UInt32 长度前缀 + 内容
    mutating func readLengthPrefixedData() throws -> Data {
        let length: UInt32 = try read()
        return try readData(count: Int(length))
    }

    mutating func readString() throws -> String {
        guard let string = try String(data: readLengthPrefixedData(), encoding: .utf8) else {
            throw FaceplantError.callMessageCorrupted("字符串不是 UTF-8")
        }
        return string
    }

    /// 跳过 `count` 字节，返回跳过前的偏移，给需要整段数据的解码器用
    mutating func skip(_ count: Int) throws -> Int {
        guard count >= 0, remaining >= count else { throw FaceplantError.callMessageCorrupted("跳过 \(count) 字节时数据不足") }
        let start = offset
        offset += count
        return start
    }
}

extension Data {
    mutating func appendLengthPrefixed(_ payload: Data) {
        appendValue(UInt32(payload.count))
        append(payload)
    }

    mutating func appendString(_ string: String) {
        appendLengthPrefixed(Data(string.utf8))
    }
}
