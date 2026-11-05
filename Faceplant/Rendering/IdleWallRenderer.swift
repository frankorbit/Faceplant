import Metal
import simd

/// 静态场景里还没有脸可画时画整面墙，并在脸将要出现的位置叠一圈缓慢呼吸的光晕，表示"在等对方"。
///
/// 墙纹的贴图映射与脸 pass 的墙面补丁完全相同（见 `FaceplantRenderer.makeFaceUniforms`），
/// 脸一到由补丁 pass 接管，砖缝不会错位。线程约束：只在 MTKView 的绘制线程使用。
final class IdleWallRenderer {
    /// 墙的半边长（米），要大到环绕相机转到任何极限角度都看不到边
    private static let halfExtent: Float = 10
    /// 呼吸周期（秒）
    private static let breathPeriod: Float = 4
    private static let glowStrengthRange: ClosedRange<Float> = 0.12 ... 0.32

    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let quadBuffer: MTLBuffer

    /// 光晕中心与半径（脸局部坐标，米），默认是一张脸的大小
    var glowCenter = SIMD2<Float>(0, 0)
    var glowRadius = SIMD2<Float>(0.16, 0.2)
    var glowColor = SIMD3<Float>(1, 0.9, 0.72)

    init(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) throws {
        pipeline = try FaceplantRenderer.makePipeline(
            device: device, library: library,
            spec: FaceplantRenderer.PipelineSpec(label: "IdleWall", vertex: "idleWallVertex", fragment: "idleWallFragment"),
            colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat
        )
        // 这一帧里只有这面墙，不需要深度
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        guard let state = device.makeDepthStencilState(descriptor: descriptor) else { throw FaceplantError.metalUnavailable }
        depthState = state

        let half = Self.halfExtent
        let corners = [
            SIMD3<Float>(-half, -half, 0), SIMD3<Float>(half, -half, 0), SIMD3<Float>(half, half, 0),
            SIMD3<Float>(-half, -half, 0), SIMD3<Float>(half, half, 0), SIMD3<Float>(-half, half, 0),
        ]
        let length = corners.count * MemoryLayout<SIMD3<Float>>.stride
        guard let buffer = device.makeBuffer(bytes: corners, length: length, options: .storageModeShared) else {
            throw FaceplantError.bufferCreationFailed(label: "IdleWallQuad")
        }
        buffer.label = "IdleWallQuad"
        quadBuffer = buffer
    }

    /// - Parameters:
    ///   - projectionView: 墙在世界原点的 z = 0 平面上，所以直接用 projection * view
    ///   - wallTileSize: 一张贴图铺几米，与 `FaceRenderParameters.wallTileSize` 一致
    ///   - time: 驱动呼吸的时间（秒），用 `CACurrentMediaTime()` 即可
    func draw(
        encoder: MTLRenderCommandEncoder, wall: MTLTexture, projectionView: simd_float4x4, wallTileSize: Float, time: CFTimeInterval
    ) {
        // 取模再转 Float，避免长时间运行后精度掉到呼吸发抖
        let phase = Float(time.truncatingRemainder(dividingBy: Double(Self.breathPeriod))) / Self.breathPeriod
        let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
        let range = Self.glowStrengthRange
        var uniforms = IdleWallUniforms(
            projectionViewModel: projectionView,
            // 贴图 v 轴朝下而墙面 y 轴朝上，y 取反，和脸 pass 保持一致
            wallScale: SIMD2<Float>(1 / wallTileSize, -1 / wallTileSize),
            wallOffset: SIMD2<Float>(repeating: 0.5),
            glowCenter: glowCenter,
            glowRadius: glowRadius,
            glowColor: glowColor,
            glowStrength: range.lowerBound + (range.upperBound - range.lowerBound) * breath
        )
        let uniformsIndex = Int(IdleWallBufferIndexUniforms.rawValue)
        encoder.pushDebugGroup("IdleWall")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: Int(IdleWallBufferIndexVertices.rawValue))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<IdleWallUniforms>.stride, index: uniformsIndex)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<IdleWallUniforms>.stride, index: uniformsIndex)
        encoder.setFragmentTexture(wall, index: Int(IdleWallTextureIndexWall.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
    }
}
