import Foundation
import Metal
import os

/// 实时追踪数据源：保存最近一帧网格与烘焙贴图。
///
/// 写入发生在 ARSession delegate 队列，读取可能来自渲染线程，所以用锁保护。
final class LiveFaceMeshSource: FaceMeshSource {
    let topology: FaceMeshTopology

    private struct State {
        var frame: FaceMeshFrame?
        var texture: MTLTexture?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(topology: FaceMeshTopology) {
        self.topology = topology
    }

    func update(frame: FaceMeshFrame, texture: MTLTexture?) {
        state.withLock {
            $0.frame = frame
            $0.texture = texture
        }
    }

    func currentFrame(at hostTime: TimeInterval) -> FaceMeshFrame? {
        state.withLock { $0.frame }
    }

    var faceTexture: MTLTexture? {
        state.withLock { $0.texture }
    }
}
