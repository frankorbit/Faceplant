import ARKit
import Metal
import simd

/// Metal 离屏 pass：把当前相机画面按 canonical UV 展开成正方形贴图。
///
/// 输出纹理双缓冲，调用方拿到的纹理在下一次 bake 之前有效。
/// 线程约束：在单一队列调用（ARSession delegate 队列），内部不加锁。
final class FaceTextureBaker {
    let textureSize: Int
    let topology: FaceMeshTopology

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let uvBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer

    private static let inflightCount = 3
    private let vertexBuffers: [MTLBuffer]
    private let outputs: [MTLTexture]
    private let inflight = DispatchSemaphore(value: FaceTextureBaker.inflightCount)
    private var frameIndex = 0

    init(device: MTLDevice, topology: FaceMeshTopology, textureSize: Int = 1024) throws {
        self.device = device
        self.topology = topology
        self.textureSize = textureSize

        guard let queue = device.makeCommandQueue() else { throw FaceplantError.metalUnavailable }
        commandQueue = queue

        guard let library = device.makeDefaultLibrary() else { throw FaceplantError.metalLibraryMissing }
        guard let vertexFunction = library.makeFunction(name: "bakeVertex") else {
            throw FaceplantError.shaderFunctionMissing("bakeVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "bakeFragment") else {
            throw FaceplantError.shaderFunctionMissing("bakeFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "FaceTextureBake"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw FaceplantError.pipelineCreationFailed(underlying: error)
        }

        uvBuffer = try Self.makeBuffer(device: device, array: topology.textureCoordinates, label: "FaceUVs")
        indexBuffer = try Self.makeBuffer(device: device, array: topology.triangleIndices, label: "FaceIndices")

        let vertexLength = topology.vertexCount * MemoryLayout<SIMD3<Float>>.stride
        vertexBuffers = try (0 ..< Self.inflightCount).map { index in
            guard let buffer = device.makeBuffer(length: vertexLength, options: .storageModeShared) else {
                throw FaceplantError.bufferCreationFailed(label: "FaceVertices\(index)")
            }
            buffer.label = "FaceVertices\(index)"
            return buffer
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: textureSize, height: textureSize, mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private
        outputs = try (0 ..< 2).map { index in
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                throw FaceplantError.textureCreationFailed(label: "BakedFace\(index)")
            }
            texture.label = "BakedFace\(index)"
            return texture
        }
    }

    /// 提交一次烘焙。返回本次写入的输出纹理；GPU 完成前内容未定，但同一 device 上后续读取会自动排在后面。
    ///
    /// - Parameter beforeCommit: 渲染编码完成、命令缓冲提交之前的钩子。录制器用它把结果 blit 进视频像素缓冲，
    ///   这样显示与录制共用一次烘焙，不需要第二个 pass。
    func bake(
        vertices: [SIMD3<Float>],
        uniforms: BakeUniforms,
        camera: PixelBufferTextureCache.CameraPlanes,
        beforeCommit: ((MTLCommandBuffer, MTLTexture) -> Void)? = nil
    ) -> MTLTexture {
        inflight.wait()

        let slot = frameIndex % Self.inflightCount
        let output = outputs[frameIndex % outputs.count]
        frameIndex += 1

        let vertexBuffer = vertexBuffers[slot]
        let byteCount = min(vertices.count * MemoryLayout<SIMD3<Float>>.stride, vertexBuffer.length)
        vertices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            vertexBuffer.contents().copyMemory(from: base, byteCount: byteCount)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflight.signal()
            return output
        }
        commandBuffer.label = "FaceBake"

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = output
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            inflight.signal()
            return output
        }
        var uniforms = uniforms
        encoder.label = "FaceBakeEncoder"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BakeBufferIndexVertices.rawValue))
        encoder.setVertexBuffer(uvBuffer, offset: 0, index: Int(BakeBufferIndexUVs.rawValue))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<BakeUniforms>.stride, index: Int(BakeBufferIndexUniforms.rawValue))
        encoder.setFragmentTexture(camera.luma.texture, index: Int(BakeTextureIndexLuma.rawValue))
        encoder.setFragmentTexture(camera.chroma.texture, index: Int(BakeTextureIndexChroma.rawValue))
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: topology.indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        encoder.endEncoding()

        beforeCommit?(commandBuffer, output)

        // 闭包持有 camera，保证 IOSurface 在 GPU 读取完成前不被回收
        commandBuffer.addCompletedHandler { [inflight] _ in
            _ = camera
            inflight.signal()
        }
        commandBuffer.commit()
        return output
    }

    private static func makeBuffer<T>(device: MTLDevice, array: [T], label: String) throws -> MTLBuffer {
        let length = array.count * MemoryLayout<T>.stride
        let made: MTLBuffer? = array.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, length > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: length, options: .storageModeShared)
        }
        guard let buffer = made else {
            throw FaceplantError.bufferCreationFailed(label: label)
        }
        buffer.label = label
        return buffer
    }
}
