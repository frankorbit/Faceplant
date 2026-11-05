import Foundation

/// 顺序写入 mesh.bin。单线程使用（ARSession delegate 队列）。
final class MeshStreamWriter {
    private let handle: FileHandle
    private let vertexCount: Int
    private let flags: MeshStreamFormat.Flags
    private(set) var frameCount: UInt32 = 0
    private var isFinished = false

    init(url: URL, vertexCount: Int, includesBlendShapes: Bool, includesEyeTransforms: Bool) throws {
        self.vertexCount = vertexCount
        var flags: MeshStreamFormat.Flags = [.halfFloatVertices]
        if includesBlendShapes { flags.insert(.blendShapes) }
        if includesEyeTransforms { flags.insert(.eyeTransforms) }
        self.flags = flags

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FaceplantError.recordingSetupFailed("无法创建 \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)

        var header = Data(capacity: MeshStreamFormat.headerSize)
        header.appendValue(MeshStreamFormat.magic)
        header.appendValue(MeshStreamFormat.version)
        header.appendValue(UInt32(vertexCount))
        header.appendValue(UInt32(0))
        header.appendValue(flags.rawValue)
        header.append(Data(count: MeshStreamFormat.headerSize - header.count))
        try handle.write(contentsOf: header)
    }

    func append(_ frame: FaceMeshFrame) throws {
        guard !isFinished else { throw FaceplantError.recordingSetupFailed("MeshStreamWriter 已结束") }
        try handle.write(contentsOf: MeshFrameCodec.encode(frame, vertexCount: vertexCount, flags: flags))
        frameCount += 1
    }

    /// 回填帧数并关闭文件。之后不能再 append。
    func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        try handle.seek(toOffset: UInt64(MeshStreamFormat.frameCountOffset))
        var count = frameCount
        try handle.write(contentsOf: Data(bytes: &count, count: MemoryLayout<UInt32>.size))
        try handle.close()
    }
}
