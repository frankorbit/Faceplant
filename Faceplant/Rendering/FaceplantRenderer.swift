import ARKit
import Metal
import MetalKit
import os
import simd

/// 脸的 Metal 渲染器，三个 pass 共用一个 encoder：
/// 背景 pass 画相机画面或静态墙面，墙面补丁 pass 把脸周围的墙纹向外推开，脸 pass 把脸连同鼓包挤出墙面。
///
/// 两种场景：
/// - `.ar`：放置页，相机帧直接读 `session.currentFrame`，脸挂在用户放置的 ARAnchor 上。
/// - `.still`：录制页的实时预览，背景是一张静态贴图，脸固定在原点、墙面是 z = 0 平面，虚拟相机在 +z 处看过去。
///
/// 线程约束：所有属性与 `draw(in:)` 都在主线程（MTKView 的回调线程）访问。
final class FaceplantRenderer: NSObject {
    enum Scene {
        case ar(ARSession)
        /// 静态墙面：脸在原点，墙是 z = 0 平面上一块按 `wallTileSize` 平铺的贴图，相机绕脸环绕
        case still(background: MTLTexture, camera: OrbitCamera)

        var isStill: Bool {
            if case .still = self { return true }
            return false
        }
    }

    /// 静态墙面上一张贴图铺多大（米）。砖墙贴图一行 6 块砖，1 米正好是 17 cm 一块
    static let wallTileSize: Float = 1.0

    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "renderer")
    private static let inflightCount = 3
    /// AR 场景里墙面补丁的半边长是脸半径的多少倍；shader 里超过 warpOuter 的片元会丢弃，补丁只要够大即可
    private static let wallPatchExtent: Float = 4
    /// 静态场景里补丁就是整面墙，要大到任何角度都出不了边
    private static let stillWallExtent: Float = 120
    /// 补丁贴在墙面稍后一点，避免和脸的鼓包底边 z-fighting
    private static let wallPatchDepth: Float = -0.001

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: PixelBufferTextureCache
    private let backgroundPipeline: MTLRenderPipelineState
    private let wallPipeline: MTLRenderPipelineState
    private let facePipeline: MTLRenderPipelineState
    private let backgroundDepthState: MTLDepthStencilState
    private let sceneDepthState: MTLDepthStencilState
    private let inflight = DispatchSemaphore(value: FaceplantRenderer.inflightCount)
    private var frameIndex = 0

    /// 与当前 source 的拓扑绑定的 GPU 资源，source 换了就重建。
    /// 脸的椭圆范围与鼻尖高度从第一帧算，之后不随表情变。
    private struct MeshResources {
        /// source 给的拓扑，用来判断是否要重建
        let sourceTopology: FaceMeshTopology
        /// 加鼓包后的拓扑，GPU 缓冲按它分配
        let skirt: FaceSkirt
        var topology: FaceMeshTopology { skirt.topology }
        let uvBuffer: MTLBuffer
        let indexBuffer: MTLBuffer
        let vertexBuffers: [MTLBuffer]
        let normalBuffers: [MTLBuffer]
        let wallBuffer: MTLBuffer
        /// 每个顶点到外轮廓的测地距离，鼓包顶点为负
        let rimBuffer: MTLBuffer
        let faceCenter: SIMD2<Float>
        let faceRadius: SIMD2<Float>
        /// 外轮廓在 face 局部坐标里最靠后的 z，整个轮廓抬到墙前就靠它
        let rimMinZ: Float
    }

    /// 本帧背景与相机参数，AR 与静态场景统一成这一组
    private struct CameraInput {
        let luma: MTLTexture
        let chroma: MTLTexture?
        let isRGB: Bool
        let displayInverse: simd_float3x3
        let projection: simd_float4x4
        let view: simd_float4x4
        let anchorTransform: simd_float4x4?
        /// 持有相机纹理的 IOSurface 到 GPU 读完
        let retained: Any?
    }

    private var mesh: MeshResources?
    private var lastVertices: [SIMD3<Float>]?

    var scene: Scene
    /// 要渲染的脸；为 nil 只画背景
    var source: FaceMeshSource? {
        didSet {
            if source?.topology != mesh?.sourceTopology {
                mesh = nil
                lastVertices = nil
            }
        }
    }

    /// AR 场景里脸所在的 ARAnchor，由放置逻辑维护；为 nil 只画背景
    var faceAnchorIdentifier: UUID?
    var parameters = FaceRenderParameters.standard
    /// 每次绘制开始时调用，回放器用它拉新视频帧
    var onDraw: ((CFTimeInterval) -> Void)?

    init(device: MTLDevice, scene: Scene, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.scene = scene
        guard let queue = device.makeCommandQueue() else { throw FaceplantError.metalUnavailable }
        commandQueue = queue
        textureCache = try PixelBufferTextureCache(device: device)

        guard let library = device.makeDefaultLibrary() else { throw FaceplantError.metalLibraryMissing }
        backgroundPipeline = try Self.makePipeline(
            device: device, library: library,
            spec: PipelineSpec(label: "Background", vertex: "backgroundVertex", fragment: "backgroundFragment"),
            colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat
        )
        wallPipeline = try Self.makePipeline(
            device: device, library: library,
            spec: PipelineSpec(label: "WallPatch", vertex: "wallVertex", fragment: "wallFragment"),
            colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat
        )
        facePipeline = try Self.makePipeline(
            device: device, library: library,
            spec: PipelineSpec(label: "Face", vertex: "faceVertex", fragment: "faceFragment"),
            colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat
        )

        let backgroundDepth = MTLDepthStencilDescriptor()
        backgroundDepth.depthCompareFunction = .always
        backgroundDepth.isDepthWriteEnabled = false
        let sceneDepth = MTLDepthStencilDescriptor()
        sceneDepth.depthCompareFunction = .less
        sceneDepth.isDepthWriteEnabled = true
        guard let backgroundState = device.makeDepthStencilState(descriptor: backgroundDepth),
              let sceneState = device.makeDepthStencilState(descriptor: sceneDepth)
        else {
            throw FaceplantError.metalUnavailable
        }
        backgroundDepthState = backgroundState
        sceneDepthState = sceneState
        super.init()
    }

    private struct PipelineSpec {
        let label: String
        let vertex: String
        let fragment: String
    }

    private static func makePipeline(
        device: MTLDevice, library: MTLLibrary, spec: PipelineSpec,
        colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: spec.vertex) else {
            throw FaceplantError.shaderFunctionMissing(spec.vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: spec.fragment) else {
            throw FaceplantError.shaderFunctionMissing(spec.fragment)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = spec.label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw FaceplantError.pipelineCreationFailed(underlying: error)
        }
    }

    // MARK: - 网格资源

    private func makeMeshResources(topology sourceTopology: FaceMeshTopology, firstVertices: [SIMD3<Float>]) throws -> MeshResources {
        let skirt = FaceSkirt(base: sourceTopology)
        let topology = skirt.topology
        let uvBuffer = try makeBuffer(array: topology.textureCoordinates, label: "FaceUVs")
        let indexBuffer = try makeBuffer(array: topology.triangleIndices, label: "FaceIndices")
        let length = topology.vertexCount * MemoryLayout<SIMD3<Float>>.stride
        let vertexBuffers = try (0 ..< Self.inflightCount).map { try makeBuffer(length: length, label: "FaceVertices\($0)") }
        let normalBuffers = try (0 ..< Self.inflightCount).map { try makeBuffer(length: length, label: "FaceNormals\($0)") }

        let rims = FaceMeshRim.distances(vertices: firstVertices, triangleIndices: sourceTopology.triangleIndices, outerLoop: skirt.loop)
            + skirt.rims
        let rimBuffer = try makeBuffer(array: rims, label: "FaceRim")

        let rimMinZ = skirt.loop.compactMap { $0 < firstVertices.count ? firstVertices[$0].z : nil }.min() ?? 0
        let depthOffset = Self.depthOffset(rimMinZ: rimMinZ, parameters: parameters)
        let (center, radius) = Self.faceBounds(vertices: firstVertices, depthScale: parameters.depthScale, depthOffset: depthOffset)
        let half = radius * (scene.isStill ? Self.stillWallExtent : Self.wallPatchExtent)
        let depth = Self.wallPatchDepth
        let corners = [
            SIMD3<Float>(center.x - half.x, center.y - half.y, depth),
            SIMD3<Float>(center.x + half.x, center.y - half.y, depth),
            SIMD3<Float>(center.x + half.x, center.y + half.y, depth),
            SIMD3<Float>(center.x - half.x, center.y + half.y, depth),
        ]
        let quad = [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]]
        let wallBuffer = try makeBuffer(array: quad, label: "WallPatch")

        return MeshResources(
            sourceTopology: sourceTopology, skirt: skirt, uvBuffer: uvBuffer, indexBuffer: indexBuffer,
            vertexBuffers: vertexBuffers, normalBuffers: normalBuffers, wallBuffer: wallBuffer, rimBuffer: rimBuffer,
            faceCenter: center, faceRadius: radius, rimMinZ: rimMinZ
        )
    }

    /// 让外轮廓最低点离墙 rimClearance，整张网格都在墙前、不被切，鼓包把轮廓到墙面全部包住；
    /// sinkDepth 再把脸往墙里按，按进去的部分由切平面处理
    private static func depthOffset(rimMinZ: Float, parameters: FaceRenderParameters) -> Float {
        FaceRenderParameters.rimClearance - rimMinZ * parameters.depthScale - parameters.sinkDepth
    }

    /// 墙前顶点在 xy 平面上的包围盒：中心与半径。全在墙后时退回整张网格。
    private static func faceBounds(
        vertices: [SIMD3<Float>], depthScale: Float, depthOffset: Float
    ) -> (center: SIMD2<Float>, radius: SIMD2<Float>) {
        var visible = vertices.filter { $0.z * depthScale + depthOffset > 0 }
        if visible.isEmpty { visible = vertices }
        guard let first = visible.first else { return (SIMD2(0, 0), SIMD2(0.07, 0.1)) }
        var low = SIMD2<Float>(first.x, first.y)
        var high = low
        for vertex in visible {
            low = simd_min(low, SIMD2(vertex.x, vertex.y))
            high = simd_max(high, SIMD2(vertex.x, vertex.y))
        }
        let radius = simd_max((high - low) * 0.5, SIMD2<Float>(repeating: 0.01))
        return ((high + low) * 0.5, radius)
    }

    private func makeBuffer<T>(array: [T], label: String) throws -> MTLBuffer {
        let length = array.count * MemoryLayout<T>.stride
        let buffer = try makeBuffer(length: length, label: label)
        array.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: length)
        }
        return buffer
    }

    private func makeBuffer(length: Int, label: String) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: max(length, 1), options: .storageModeShared) else {
            throw FaceplantError.bufferCreationFailed(label: label)
        }
        buffer.label = label
        return buffer
    }

    private static func upload<T>(_ array: [T], to buffer: MTLBuffer) {
        let byteCount = min(array.count * MemoryLayout<T>.stride, buffer.length)
        array.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: byteCount)
        }
    }

    // MARK: - 场景输入

    private func makeCameraInput(viewport: CGSize) -> CameraInput? {
        switch scene {
        case let .ar(session):
            guard let frame = session.currentFrame else { return nil }
            let planes: PixelBufferTextureCache.CameraPlanes
            do {
                planes = try textureCache.cameraPlanes(for: frame.capturedImage)
            } catch {
                Self.logger.error("相机纹理失败: \(String(describing: error))")
                return nil
            }
            textureCache.flush()
            let anchor = faceAnchorIdentifier.flatMap { id in frame.anchors.first { $0.identifier == id } }
            return CameraInput(
                luma: planes.luma.texture,
                chroma: planes.chroma.texture,
                isRGB: false,
                displayInverse: ProjectionMath.float3x3(frame.displayTransform(for: .portrait, viewportSize: viewport).inverted()),
                projection: frame.camera.projectionMatrix(for: .portrait, viewportSize: viewport, zNear: 0.01, zFar: 100),
                view: frame.camera.viewMatrix(for: .portrait),
                anchorTransform: anchor?.transform,
                retained: planes
            )
        case let .still(background, camera):
            return CameraInput(
                luma: background,
                chroma: nil,
                isRGB: true,
                displayInverse: matrix_identity_float3x3,
                projection: Self.perspective(fovY: .pi / 4, aspect: Float(viewport.width / max(viewport.height, 1)), near: 0.01, far: 10),
                view: camera.viewMatrix,
                anchorTransform: matrix_identity_float4x4,
                retained: nil
            )
        }
    }
}

// MARK: - MTKViewDelegate

extension FaceplantRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        onDraw?(CACurrentMediaTime())
        let viewport = view.drawableSize
        guard viewport.width > 0, viewport.height > 0,
              let input = makeCameraInput(viewport: viewport),
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else { return }

        inflight.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            inflight.signal()
            return
        }
        commandBuffer.label = "Faceplant"
        encoder.label = "FaceplantEncoder"
        // 静态墙面由补丁 pass 整面画出来，背景只需要清屏
        if !input.isRGB {
            encodeBackground(encoder: encoder, input: input)
        }
        encodeScene(encoder: encoder, input: input, viewport: viewport)
        encoder.endEncoding()

        // 闭包持有相机纹理，保证 IOSurface 在 GPU 读取完成前不被回收
        let retained = input.retained
        commandBuffer.addCompletedHandler { [inflight] _ in
            _ = retained
            inflight.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameIndex += 1
    }

    private func encodeBackground(encoder: MTLRenderCommandEncoder, input: CameraInput) {
        var uniforms = BackgroundUniforms(displayTransformInverse: input.displayInverse, cameraIsRGB: input.isRGB ? 1 : 0)
        encoder.pushDebugGroup("Background")
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setDepthStencilState(backgroundDepthState)
        encoder.setCullMode(.none)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<BackgroundUniforms>.stride,
            index: Int(BackgroundBufferIndexUniforms.rawValue)
        )
        encoder.setFragmentTexture(input.luma, index: Int(BackgroundTextureIndexLuma.rawValue))
        encoder.setFragmentTexture(input.chroma ?? input.luma, index: Int(BackgroundTextureIndexChroma.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.popDebugGroup()
    }

    /// 墙面补丁 + 脸（含鼓包），两者共用 uniform 与相机纹理
    private func encodeScene(encoder: MTLRenderCommandEncoder, input: CameraInput, viewport: CGSize) {
        guard let source, let anchorTransform = input.anchorTransform, let faceTexture = source.faceTexture else { return }

        // 本帧没有新数据就沿用上一帧的顶点
        if let frameData = source.currentFrame(at: CACurrentMediaTime()), frameData.vertices.count == source.topology.vertexCount {
            lastVertices = frameData.vertices
        }
        guard let vertices = lastVertices, let mesh = ensureMesh(topology: source.topology, firstVertices: vertices) else { return }

        // 鼓包底部随 depthScale/sinkDepth 变，所以每帧重算
        let depthOffset = Self.depthOffset(rimMinZ: mesh.rimMinZ, parameters: parameters)
        let rendered = mesh.skirt.extend(vertices, shape: FaceSkirt.Shape(
            faceCenter: mesh.faceCenter,
            depthScale: parameters.depthScale,
            depthOffset: depthOffset,
            slope: parameters.skirtSlope
        ))
        let slot = frameIndex % Self.inflightCount
        Self.upload(rendered, to: mesh.vertexBuffers[slot])
        Self.upload(
            FaceMeshNormals.compute(vertices: rendered, triangleIndices: mesh.topology.triangleIndices),
            to: mesh.normalBuffers[slot]
        )
        var uniforms = makeFaceUniforms(
            input: input,
            anchorTransform: anchorTransform,
            viewport: viewport,
            mesh: mesh,
            depthOffset: depthOffset
        )

        encoder.setDepthStencilState(sceneDepthState)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FaceUniforms>.stride, index: Int(FaceBufferIndexUniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FaceUniforms>.stride, index: Int(FaceBufferIndexUniforms.rawValue))
        encoder.setFragmentTexture(input.luma, index: Int(FaceTextureIndexLuma.rawValue))
        encoder.setFragmentTexture(input.chroma ?? input.luma, index: Int(FaceTextureIndexChroma.rawValue))

        drawWallPatch(encoder: encoder, mesh: mesh)
        drawFace(encoder: encoder, mesh: mesh, slot: slot, faceTexture: faceTexture)
    }

    private func drawWallPatch(encoder: MTLRenderCommandEncoder, mesh: MeshResources) {
        encoder.pushDebugGroup("WallPatch")
        encoder.setRenderPipelineState(wallPipeline)
        encoder.setVertexBuffer(mesh.wallBuffer, offset: 0, index: Int(FaceBufferIndexVertices.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
    }

    private func drawFace(encoder: MTLRenderCommandEncoder, mesh: MeshResources, slot: Int, faceTexture: MTLTexture) {
        encoder.pushDebugGroup("Face")
        encoder.setRenderPipelineState(facePipeline)
        encoder.setVertexBuffer(mesh.vertexBuffers[slot], offset: 0, index: Int(FaceBufferIndexVertices.rawValue))
        encoder.setVertexBuffer(mesh.uvBuffer, offset: 0, index: Int(FaceBufferIndexUVs.rawValue))
        encoder.setVertexBuffer(mesh.normalBuffers[slot], offset: 0, index: Int(FaceBufferIndexNormals.rawValue))
        encoder.setVertexBuffer(mesh.rimBuffer, offset: 0, index: Int(FaceBufferIndexRim.rawValue))
        encoder.setFragmentTexture(faceTexture, index: Int(FaceTextureIndexFace.rawValue))
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: mesh.topology.indexCount,
            indexType: .uint16,
            indexBuffer: mesh.indexBuffer,
            indexBufferOffset: 0
        )
        encoder.popDebugGroup()
    }

    private func ensureMesh(topology: FaceMeshTopology, firstVertices: [SIMD3<Float>]) -> MeshResources? {
        if let mesh { return mesh }
        do {
            let created = try makeMeshResources(topology: topology, firstVertices: firstVertices)
            mesh = created
            return created
        } catch {
            Self.logger.error("网格资源创建失败: \(String(describing: error))")
            return nil
        }
    }

    private func makeFaceUniforms(
        input: CameraInput, anchorTransform: simd_float4x4, viewport: CGSize, mesh: MeshResources, depthOffset: Float
    ) -> FaceUniforms {
        let viewModel = input.view * anchorTransform
        return FaceUniforms(
            projectionViewModel: input.projection * viewModel,
            viewModel: viewModel,
            displayTransformInverse: input.displayInverse,
            viewportSize: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
            faceCenter: mesh.faceCenter,
            faceRadius: mesh.faceRadius,
            // 贴图 v 轴朝下而脸局部 y 轴朝上，y 取反
            wallScale: SIMD2<Float>(1 / Self.wallTileSize, -1 / Self.wallTileSize),
            wallOffset: SIMD2<Float>(repeating: 0.5),
            faceTint: parameters.faceTint,
            edgeFade: parameters.edgeFade,
            sideFade: parameters.sideFade,
            warpStrength: parameters.warpStrength,
            warpOuter: parameters.warpOuter,
            refractStrength: parameters.refractStrength,
            depthScale: parameters.depthScale,
            depthOffset: depthOffset,
            cameraIsRGB: input.isRGB ? 1 : 0
        )
    }
}
