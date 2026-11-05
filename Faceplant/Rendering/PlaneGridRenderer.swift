import ARKit
import Metal
import simd

/// 把 ARKit 检测到的平面画成半透明网格，提示用户哪里能放脸。
///
/// 平面几何随扫描持续变化，顶点与索引每帧重新上传；缓冲按 (anchor, inflight 槽位) 缓存并按需扩容，
/// 同一平面保留多份避免 GPU 还在读上一帧时被改写。线程约束：只在 MTKView 的绘制线程使用。
final class PlaneGridRenderer {
    private struct BufferKey: Hashable {
        let plane: UUID
        let slot: Int
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var vertexBuffers: [BufferKey: MTLBuffer] = [:]
    private var indexBuffers: [BufferKey: MTLBuffer] = [:]

    var lineColor = SIMD4<Float>(1, 1, 1, 0.7)
    /// 网格间距（米）
    var gridSpacing: Float = 0.1

    init(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) throws {
        self.device = device
        pipeline = try FaceplantRenderer.makePipeline(
            device: device, library: library,
            spec: FaceplantRenderer.PipelineSpec(label: "PlaneGrid", vertex: "planeGridVertex", fragment: "planeGridFragment"),
            colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat, blending: true
        )
        // 只做深度测试不写深度：网格是提示层，不该遮住之后画的脸
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = false
        guard let state = device.makeDepthStencilState(descriptor: descriptor) else { throw FaceplantError.metalUnavailable }
        depthState = state
    }

    /// - Parameter slot: 本帧的 inflight 槽位，与渲染器的顶点缓冲轮转一致
    func draw(encoder: MTLRenderCommandEncoder, planes: [ARPlaneAnchor], projectionView: simd_float4x4, slot: Int) {
        pruneBuffers(keeping: planes)
        guard !planes.isEmpty else { return }
        encoder.pushDebugGroup("PlaneGrid")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        for plane in planes {
            let geometry = plane.geometry
            let indexCount = geometry.triangleCount * 3
            guard !geometry.vertices.isEmpty, indexCount > 0 else { continue }
            let key = BufferKey(plane: plane.identifier, slot: slot)
            guard let vertexBuffer = upload(geometry.vertices, into: &vertexBuffers, key: key, label: "PlaneVertices"),
                  let indexBuffer = upload(geometry.triangleIndices, into: &indexBuffers, key: key, label: "PlaneIndices")
            else { continue }

            var uniforms = PlaneGridUniforms(
                projectionViewModel: projectionView * plane.transform,
                lineColor: lineColor,
                gridSpacing: gridSpacing
            )
            let uniformsIndex = Int(PlaneGridBufferIndexUniforms.rawValue)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(PlaneGridBufferIndexVertices.rawValue))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PlaneGridUniforms>.stride, index: uniformsIndex)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PlaneGridUniforms>.stride, index: uniformsIndex)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0
            )
        }
        encoder.popDebugGroup()
    }

    /// 平面消失（被合并或会话重开）后释放它的缓冲；GPU 仍在用的那几帧由 command buffer 自己持有
    private func pruneBuffers(keeping planes: [ARPlaneAnchor]) {
        let alive = Set(planes.map(\.identifier))
        vertexBuffers = vertexBuffers.filter { alive.contains($0.key.plane) }
        indexBuffers = indexBuffers.filter { alive.contains($0.key.plane) }
    }

    /// 缓冲不够大就换一块更大的，容量多留一半，平面扩张时少重分配
    private func upload<T>(_ array: [T], into table: inout [BufferKey: MTLBuffer], key: BufferKey, label: String) -> MTLBuffer? {
        let length = array.count * MemoryLayout<T>.stride
        let buffer: MTLBuffer
        if let existing = table[key], existing.length >= length {
            buffer = existing
        } else {
            guard let created = device.makeBuffer(length: max(length * 3 / 2, 256), options: .storageModeShared) else { return nil }
            created.label = label
            table[key] = created
            buffer = created
        }
        array.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: length)
        }
        return buffer
    }
}
