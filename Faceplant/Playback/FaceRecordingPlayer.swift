import AVFoundation
import Foundation
import Metal
import os

/// 回放一个录制包：视频时钟为主，顶点帧按时间戳二分查找并插值。
///
/// 线程约束：`pollTexture` 与 `currentFrame` 在渲染线程（CADisplayLink）调用；play/pause 在主线程。
final class FaceRecordingPlayer: FaceMeshSource {
    let recording: FaceRecording
    let topology: FaceMeshTopology

    private let frames: [FaceMeshFrame]
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let textureCache: PixelBufferTextureCache
    private var endObserver: NSObjectProtocol?
    private var latestTexture: PixelBufferTextureCache.TextureRef?
    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "player")

    private(set) var isPlaying = false

    init(recording: FaceRecording, device: MTLDevice) throws {
        self.recording = recording
        topology = try recording.loadTopology()
        frames = try recording.loadMeshFrames()
        guard !frames.isEmpty else { throw FaceplantError.playbackSetupFailed("录制包没有顶点帧") }
        textureCache = try PixelBufferTextureCache(device: device)

        item = AVPlayerItem(url: recording.textureURL)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none

        // 循环播放：到尾部 seek 回 0。不用 AVPlayerLooper 是因为它会复制 item，video output 需要逐个挂。
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    var duration: TimeInterval { recording.manifest.duration }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    // MARK: - FaceMeshSource

    /// 取回放时钟对应的顶点帧，相邻两帧线性插值
    func currentFrame(at hostTime: TimeInterval) -> FaceMeshFrame? {
        frame(atRecordingTime: currentTime)
    }

    var faceTexture: MTLTexture? { latestTexture?.texture }

    /// 每个显示周期调用一次，把解码出的新视频帧包成 MTLTexture
    func pollTexture(hostTime: CFTimeInterval) {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        do {
            latestTexture = try textureCache.texture(for: pixelBuffer, format: .bgra8Unorm)
            textureCache.flush()
        } catch {
            Self.logger.error("视频帧转纹理失败: \(String(describing: error))")
        }
    }

    private func frame(atRecordingTime time: TimeInterval) -> FaceMeshFrame {
        guard let last = frames.last, time < last.timestamp else { return frames[frames.count - 1] }
        guard time > frames[0].timestamp else { return frames[0] }

        // 二分找到第一个 timestamp > time 的帧
        var low = 0
        var high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].timestamp > time {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let next = frames[low]
        let previous = frames[low - 1]
        let span = next.timestamp - previous.timestamp
        guard span > 0 else { return previous }
        return FaceMeshFrame.interpolate(previous, next, fraction: Float((time - previous.timestamp) / span))
    }
}
