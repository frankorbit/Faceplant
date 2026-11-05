import Foundation
import Metal
import os
import QuartzCore

/// 通话对端的脸：拓扑来自对方的 ARKit 原始网格，这里加盖后给渲染层；顶点帧和解码出的贴图各自更新。
///
/// 顶点帧不是到一帧显示一帧，而是进一个小播出缓冲：按发送端时间戳排序，渲染时取"现在往前 `playoutDelay`"
/// 那一刻，落在两帧之间就线性插值。网络抖动和偶尔丢一帧都被插值抹平，代价是固定多出约两帧延迟。
/// 本机与发送端的时钟差用"到达时刻 − 发送时间戳"的最小值估计：往下立刻跟（更快的包更接近真实差），
/// 往上慢慢爬（抵消时钟漂移和路径变慢）。
///
/// 写入来自 MC 回调线程与解码队列，读取在渲染线程，所以用锁。
final class RemoteFaceMeshSource: FaceMeshSource {
    /// 播出延迟，约两帧
    static let playoutDelay: TimeInterval = 0.07
    /// 缓冲里最多留几帧，再多说明本机渲染跟不上，丢旧的
    private static let maxBuffered = 8
    /// 时钟差往上爬的速度
    private static let offsetRise = 0.02

    let topology: FaceMeshTopology

    private struct State {
        /// 已加盖，按 timestamp 升序
        var frames: [FaceMeshFrame] = []
        var texture: PixelBufferTextureCache.TextureRef?
        /// 本机 hostTime − 发送端 timestamp
        var clockOffset: TimeInterval?
        var lastPlayed: FaceMeshFrame?
        var underruns = 0
        var inUnderrun = false
    }

    private let capping: FaceMeshCapping
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(rawTopology: FaceMeshTopology) {
        capping = FaceMeshCapping(base: rawTopology)
        topology = capping.topology
    }

    /// 渲染时缓冲里没有下一帧可插值的累计次数（按次计，不按帧计）
    var playoutUnderruns: Int { state.withLock { $0.underruns } }

    /// 顶点数和拓扑不符的帧丢掉，不让一条坏消息把脸撕坏
    func update(frame: FaceMeshFrame) {
        guard frame.vertices.count == capping.baseVertexCount else { return }
        let arrival = CACurrentMediaTime()
        let capped = capping.extend(frame)
        state.withLock { state in
            let sample = arrival - frame.timestamp
            if let offset = state.clockOffset {
                state.clockOffset = sample < offset ? sample : offset + (sample - offset) * Self.offsetRise
            } else {
                state.clockOffset = sample
            }
            // 比已经播过的还旧（乱序到达）的帧没用了
            if let last = state.lastPlayed, frame.timestamp <= last.timestamp { return }
            let index = state.frames.firstIndex { $0.timestamp >= frame.timestamp } ?? state.frames.count
            if index < state.frames.count, state.frames[index].timestamp == frame.timestamp { return }
            state.frames.insert(capped, at: index)
            if state.frames.count > Self.maxBuffered {
                state.frames.removeFirst(state.frames.count - Self.maxBuffered)
            }
        }
    }

    func update(texture: PixelBufferTextureCache.TextureRef) {
        state.withLock { $0.texture = texture }
    }

    func currentFrame(at hostTime: TimeInterval) -> FaceMeshFrame? {
        state.withLock { state in
            guard let offset = state.clockOffset, !state.frames.isEmpty else { return state.lastPlayed }
            let target = hostTime - offset - Self.playoutDelay
            // 丢掉已经过去的帧，但留最后一个当插值起点
            while state.frames.count > 1, state.frames[1].timestamp <= target {
                state.frames.removeFirst()
            }
            let from = state.frames[0]
            let played: FaceMeshFrame
            if target <= from.timestamp {
                // 刚连上，还没到第一帧的播出时刻，先把它显示出来
                played = from
                state.inUnderrun = false
            } else if state.frames.count >= 2 {
                let to = state.frames[1]
                let fraction = Float((target - from.timestamp) / max(to.timestamp - from.timestamp, 1e-4))
                played = FaceMeshFrame.interpolate(from, to, fraction: fraction)
                state.inUnderrun = false
            } else {
                // 下一帧还没到：保持最后一帧，一次欠载只计一次
                if !state.inUnderrun {
                    state.underruns += 1
                    state.inUnderrun = true
                }
                played = from
            }
            state.lastPlayed = played
            return played
        }
    }

    var faceTexture: MTLTexture? {
        state.withLock { $0.texture?.texture }
    }
}
