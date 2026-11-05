import Foundation

/// 一次性把 mesh.bin 读进内存。十几秒的录制只有几 MB，不需要流式读取。
enum MeshStreamReader {
    static func read(url: URL) throws -> [FaceMeshFrame] {
        let data = try Data(contentsOf: url)
        guard data.count >= MeshStreamFormat.headerSize else {
            throw FaceplantError.meshStreamCorrupted("文件太短")
        }
        let magic: UInt32 = data.loadValue(at: 0)
        let version: UInt32 = data.loadValue(at: 4)
        guard magic == MeshStreamFormat.magic, version == MeshStreamFormat.version else {
            throw FaceplantError.meshStreamCorrupted("魔数或版本不匹配")
        }
        let vertexCount = Int(data.loadValue(at: 8) as UInt32)
        let frameCount = Int(data.loadValue(at: MeshStreamFormat.frameCountOffset) as UInt32)
        let flags = MeshStreamFormat.Flags(rawValue: data.loadValue(at: 16))
        guard flags.contains(.halfFloatVertices) else {
            throw FaceplantError.meshStreamCorrupted("只支持 Float16 顶点流")
        }

        let frameSize = MeshStreamFormat.frameByteCount(vertexCount: vertexCount, flags: flags)
        guard data.count == MeshStreamFormat.headerSize + frameCount * frameSize else {
            throw FaceplantError.meshStreamCorrupted("长度与头部不符：期望 \(frameCount) 帧")
        }

        var frames = [FaceMeshFrame]()
        frames.reserveCapacity(frameCount)
        for index in 0 ..< frameCount {
            let offset = MeshStreamFormat.headerSize + index * frameSize
            try frames.append(MeshFrameCodec.decode(data, at: offset, vertexCount: vertexCount, flags: flags))
        }
        return frames
    }
}
