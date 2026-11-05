import Foundation
import os
import QuartzCore

/// 通话链路的计数器：收发速率、按时间戳间隔推算的丢帧、发送失败、播出缓冲欠载、热状态。
/// 页面每秒取一次快照显示在角落，真机上先看这一行再决定优化哪一段。所有方法线程安全。
final class CallStatistics {
    /// 发送端顶点帧的名义间隔（30 fps 追踪，每帧都发），用来把时间戳空洞折算成丢帧数
    static let expectedMeshInterval: TimeInterval = 1.0 / 30

    struct Snapshot {
        var meshReceivedPerSecond = 0
        /// 丢帧占应到帧数的百分比
        var meshDroppedPercent = 0
        var videoReceivedPerSecond = 0
        var audioReceivedPerSecond = 0
        var meshSentPerSecond = 0
        /// 累计
        var sendFailures = 0
        var playoutDelay: TimeInterval = 0
        /// 累计：渲染时缓冲里没有可插值的下一帧的次数
        var playoutUnderruns = 0
        var thermalState = ProcessInfo.ThermalState.nominal

        /// 两行等宽文字，放角落
        var description: String {
            let heat = switch thermalState {
            case .nominal: "正常"
            case .fair: "偏热"
            case .serious: "高"
            case .critical: "严重"
            @unknown default: "未知"
            }
            let delay = Int((playoutDelay * 1000).rounded())
            return "收 顶点 \(meshReceivedPerSecond)/s 丢 \(meshDroppedPercent)% 贴图 \(videoReceivedPerSecond)/s 声 \(audioReceivedPerSecond)/s\n"
                + "发 顶点 \(meshSentPerSecond)/s 失败 \(sendFailures) 缓冲 \(delay)ms 欠 \(playoutUnderruns) 热 \(heat)"
        }
    }

    private struct Counters {
        var meshReceived = 0
        var meshDropped = 0
        var video = 0
        var audio = 0
        var meshSent = 0
        var sendFailures = 0
        var lastMeshTimestamp: TimeInterval?
        var lastSnapshot = CACurrentMediaTime()
    }

    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    /// - Parameter timestamp: 发送端的 ARFrame 时间戳；比上一帧还旧的乱序包不参与丢帧估计
    func meshReceived(timestamp: TimeInterval) {
        counters.withLock { state in
            state.meshReceived += 1
            if let last = state.lastMeshTimestamp {
                let gap = timestamp - last
                guard gap > 0 else { return }
                if gap > Self.expectedMeshInterval * 1.5 {
                    state.meshDropped += Int((gap / Self.expectedMeshInterval).rounded()) - 1
                }
            }
            state.lastMeshTimestamp = timestamp
        }
    }

    func videoReceived() {
        counters.withLock { $0.video += 1 }
    }

    func audioReceived() {
        counters.withLock { $0.audio += 1 }
    }

    func meshSent() {
        counters.withLock { $0.meshSent += 1 }
    }

    func sendFailed() {
        counters.withLock { $0.sendFailures += 1 }
    }

    /// 取上次快照以来的速率并清零区间计数；累计量不清
    func snapshot(playoutDelay: TimeInterval, playoutUnderruns: Int) -> Snapshot {
        counters.withLock { state in
            let now = CACurrentMediaTime()
            let seconds = max(now - state.lastSnapshot, 1e-3)
            let perSecond = { (count: Int) in Int((Double(count) / seconds).rounded()) }
            let expected = state.meshReceived + state.meshDropped
            var snapshot = Snapshot()
            snapshot.meshReceivedPerSecond = perSecond(state.meshReceived)
            snapshot.meshDroppedPercent = expected > 0 ? Int((Double(state.meshDropped) / Double(expected) * 100).rounded()) : 0
            snapshot.videoReceivedPerSecond = perSecond(state.video)
            snapshot.audioReceivedPerSecond = perSecond(state.audio)
            snapshot.meshSentPerSecond = perSecond(state.meshSent)
            snapshot.sendFailures = state.sendFailures
            snapshot.playoutDelay = playoutDelay
            snapshot.playoutUnderruns = playoutUnderruns
            snapshot.thermalState = ProcessInfo.processInfo.thermalState
            state.meshReceived = 0
            state.meshDropped = 0
            state.video = 0
            state.audio = 0
            state.meshSent = 0
            state.lastSnapshot = now
            return snapshot
        }
    }
}
