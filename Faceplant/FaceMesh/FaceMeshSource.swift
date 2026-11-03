import Foundation
import Metal

/// 渲染层的唯一网格入口。实时追踪和录制回放都实现它，渲染层不关心数据从哪来。
protocol FaceMeshSource: AnyObject {
    var topology: FaceMeshTopology { get }
    /// 返回当前应渲染的帧；nil 表示本帧没有新数据，渲染层沿用上一帧。
    func currentFrame(at hostTime: TimeInterval) -> FaceMeshFrame?
    /// 脸的贴图。实时模式下由 baker 每帧更新，回放模式下由 player 更新。
    var faceTexture: MTLTexture? { get }
}
