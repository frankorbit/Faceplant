import Foundation
import Metal
import os

/// 通话对端的脸：拓扑来自对方的 ARKit 原始网格，这里加盖后给渲染层；顶点帧和解码出的贴图各自更新。
///
/// 写入来自 MC 回调线程与解码队列，读取在渲染线程，所以用锁。
final class RemoteFaceMeshSource: FaceMeshSource {
    let topology: FaceMeshTopology

    private struct State {
        var frame: FaceMeshFrame?
        var texture: PixelBufferTextureCache.TextureRef?
    }

    private let capping: FaceMeshCapping
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(rawTopology: FaceMeshTopology) {
        capping = FaceMeshCapping(base: rawTopology)
        topology = capping.topology
    }

    /// 顶点数和拓扑不符的帧丢掉，不让一条坏消息把脸撕坏
    func update(frame: FaceMeshFrame) {
        guard frame.vertices.count == capping.baseVertexCount else { return }
        let capped = capping.extend(frame)
        state.withLock { $0.frame = capped }
    }

    func update(texture: PixelBufferTextureCache.TextureRef) {
        state.withLock { $0.texture = texture }
    }

    func currentFrame(at hostTime: TimeInterval) -> FaceMeshFrame? {
        state.withLock { $0.frame }
    }

    var faceTexture: MTLTexture? {
        state.withLock { $0.texture?.texture }
    }
}
