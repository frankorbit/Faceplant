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
        guard frame.vertices.count == vertexCount else {
            throw FaceplantError.meshStreamCorrupted("顶点数 \(frame.vertices.count) 与拓扑 \(vertexCount) 不符")
        }

        var data = Data(capacity: MeshStreamFormat.frameByteCount(vertexCount: vertexCount, flags: flags))
        data.appendValue(frame.timestamp)

        var halves = [Float16]()
        halves.reserveCapacity(vertexCount * 3)
        for vertex in frame.vertices {
            halves.append(Float16(vertex.x))
            halves.append(Float16(vertex.y))
            halves.append(Float16(vertex.z))
        }
        data.appendArray(halves)

        if flags.contains(.blendShapes) {
            let blendShapes = frame.blendShapes ?? Array(repeating: 0, count: BlendShapeOrder.count)
            guard blendShapes.count == BlendShapeOrder.count else {
                throw FaceplantError.meshStreamCorrupted("blendShape 数量 \(blendShapes.count) 不符")
            }
            data.appendArray(blendShapes)
        }

        if flags.contains(.eyeTransforms) {
            // 没有眼球数据的帧写单位矩阵，读回后眼球会停在脸原点；录制路径总是带眼球，这只是兜底
            let eyes = frame.eyes ?? EyePose(left: matrix_identity_float4x4, right: matrix_identity_float4x4)
            data.appendArray(eyes.left.flattened + eyes.right.flattened)
        }

        try handle.write(contentsOf: data)
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
