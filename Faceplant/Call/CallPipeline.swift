import ARKit
import CoreVideo
import Foundation
import Metal
import os
import UIKit

/// 附近通话的数据流：本机脸 → 对端，对端 → 本机渲染。
///
/// 发送（ARSession delegate 队列，人脸追踪跑 30 fps）：
/// - 第一次拿到人脸就建烘焙器、发拓扑；
/// - 每帧原始顶点走不可靠信道；
/// - 每帧烘焙贴图并 blit 进像素缓冲，GPU 完成后交给 H.264 编码器，包走可靠信道；
/// - 麦克风样本原样打包走不可靠信道；
/// - 页面切到真实平面模式（后置世界追踪 + 用户人脸追踪）时 `capturedImage` 是后置画面，烘焙不了贴图，
///   `setSendsTexture(false)` 后只发顶点，新对端连上时把最后一帧烘焙好的贴图作为关键帧补发一次。
///
/// 接收（MC 回调线程）：拓扑 → 建 `RemoteFaceMeshSource`（带播出缓冲）；顶点帧 → 更新；视频 → 解码器 → 贴图；音频 → 播放。
/// 各环节的计数进 `statistics`，页面每秒显示一次。
final class CallPipeline {
    static let textureSize = 512
    /// 页面用的相机帧率；顶点和贴图都按这个频率发
    static let trackingFrameRate = 30
    private static let meshSendInterval: TimeInterval = 1.0 / Double(trackingFrameRate + 1)
    private static let videoBitrate = 1_500_000
    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "callPipeline")

    /// 对端的脸可以渲染了（nil 表示断开），主线程
    var onRemoteSourceChange: ((RemoteFaceMeshSource?) -> Void)?
    /// 一句状态，主线程
    var onStatus: ((String) -> Void)?
    /// 底部相机视图的尺寸，烘焙投影要和显示一致；主线程写，delegate 队列读
    let viewportSize = OSAllocatedUnfairLock(initialState: CGSize.zero)

    let statistics = CallStatistics()

    private let device: MTLDevice
    private let nearby: NearbySession
    private let sessionController: ARSessionController
    private let textureCache: PixelBufferTextureCache
    private let encoder: VideoEncoder
    private let decoder: VideoDecoder
    private let playout = AudioPlayout()
    private let remote = OSAllocatedUnfairLock<RemoteFaceMeshSource?>(initialState: nil)

    // 以下只在 delegate 队列访问
    private var latestAnchor: ARFaceAnchor?
    private var baker: FaceTextureBaker?
    private var capping: FaceMeshCapping?
    private var topologySent = false
    /// 刚发完拓扑，下一帧贴图要强制关键帧，对端不用等两秒
    private var needsKeyframe = false
    private var sendsTexture = true
    /// 最后一帧送去编码的贴图，不烘焙时用它补发
    private var lastBakedPixelBuffer: CVPixelBuffer?
    private var lastMeshSent: TimeInterval = 0
    private var pixelBufferPool: CVPixelBufferPool?

    init(device: MTLDevice, nearby: NearbySession, sessionController: ARSessionController) throws {
        self.device = device
        self.nearby = nearby
        self.sessionController = sessionController
        textureCache = try PixelBufferTextureCache(device: device)
        encoder = try VideoEncoder(
            width: Self.textureSize, height: Self.textureSize, bitrate: Self.videoBitrate, frameRate: Self.trackingFrameRate
        )
        decoder = try VideoDecoder(device: device)
        pixelBufferPool = Self.makePixelBufferPool(size: Self.textureSize)
        bind()
    }

    func stop() {
        encoder.invalidate()
        playout.stop()
        remote.withLock { $0 = nil }
    }

    /// 给页面显示的一行统计
    func statisticsSnapshot() -> CallStatistics.Snapshot {
        statistics.snapshot(
            playoutDelay: RemoteFaceMeshSource.playoutDelay,
            playoutUnderruns: remote.withLock { $0 }?.playoutUnderruns ?? 0
        )
    }

    /// 关掉后只发顶点不烘焙贴图；主线程调用，切到 delegate 队列生效
    func setSendsTexture(_ enabled: Bool) {
        sessionController.delegateQueue.async { [weak self] in
            guard let self, sendsTexture != enabled else { return }
            sendsTexture = enabled
            if !enabled, lastBakedPixelBuffer == nil {
                report("还没采到你的贴图，对方暂时看不到你的脸；回虚拟墙模式让前置摄像头看一眼再切过来")
            }
        }
    }

    // MARK: - 绑定

    private func bind() {
        encoder.onPacket = { [weak self] packet in
            self?.nearby.send(.video(packet), mode: .reliable)
        }
        decoder.onFrame = { [weak self] texture in
            self?.remote.withLock { $0 }?.update(texture: texture)
        }
        nearby.onMessage = { [weak self] message in
            self?.receive(message)
        }
        sessionController.onFaceAnchor = { [weak self] anchor in
            self?.latestAnchor = anchor
            self?.prepareBakerIfNeeded(anchor: anchor)
        }
        sessionController.onAudio = { [weak self] sampleBuffer in
            guard let self, nearby.isConnected, let packet = AudioPacket(sampleBuffer: sampleBuffer) else { return }
            nearby.send(.audio(packet), mode: .unreliable)
        }
    }

    /// 连接状态变化时由页面转发过来：新对端要重发一次拓扑，断开清掉对端的脸
    func handleConnection(_ state: NearbySession.State) {
        switch state {
        case .connected:
            let deviceName = UIDevice.current.name
            sessionController.delegateQueue.async { [weak self] in
                self?.topologySent = false
                self?.nearby.send(.hello(deviceName: deviceName, textureSize: Self.textureSize), mode: .reliable)
            }
        case .idle, .searching, .connecting:
            remote.withLock { $0 = nil }
            onRemoteSourceChange?(nil)
        }
    }

    // MARK: - 发送（delegate 队列）

    private func prepareBakerIfNeeded(anchor: ARFaceAnchor) {
        guard baker == nil else { return }
        let capping = FaceMeshCapping(base: FaceMeshTopology(geometry: anchor.geometry))
        do {
            baker = try FaceTextureBaker(device: device, topology: capping.topology, textureSize: Self.textureSize)
            self.capping = capping
        } catch {
            Self.logger.error("烘焙器初始化失败: \(String(describing: error))")
        }
    }

    /// 每帧由页面从 `ARSessionController.onFrame` 转发进来（delegate 队列）；页面自己也要用帧，所以不在这里独占回调
    func handle(frame: ARFrame) {
        guard nearby.isConnected, let anchor = latestAnchor, anchor.isTracked, let capping else { return }

        if !topologySent {
            nearby.send(.topology(capping.base), mode: .reliable)
            topologySent = true
            needsKeyframe = true
        }
        let meshFrame = FaceMeshFrame(anchor: anchor, timestamp: frame.timestamp)
        if frame.timestamp - lastMeshSent >= Self.meshSendInterval {
            lastMeshSent = frame.timestamp
            if nearby.send(.meshFrame(meshFrame), mode: .unreliable) {
                statistics.meshSent()
            } else {
                statistics.sendFailed()
            }
        }

        guard sendsTexture else {
            // 后置追踪时烘焙不了，新对端只能拿到切换前的最后一帧贴图
            if needsKeyframe, let lastBakedPixelBuffer {
                encoder.encode(lastBakedPixelBuffer, timestamp: frame.timestamp, forceKeyframe: true)
                needsKeyframe = false
            }
            return
        }
        let viewport = viewportSize.withLock { $0 }
        guard let baker, viewport.width > 0, viewport.height > 0 else { return }

        // 通话页不显示烘焙结果，烘焙只为编码：追踪 30 fps，每帧烘一次就是 30 fps 贴图，不再有白烘的帧
        let forceKeyframe = needsKeyframe
        do {
            let planes = try textureCache.cameraPlanes(for: frame.capturedImage)
            let uniforms = ProjectionMath.bakeUniforms(
                frame: frame, anchorTransform: anchor.transform, orientation: .portrait, viewportSize: viewport
            )
            _ = baker.bake(vertices: capping.extend(meshFrame.vertices), uniforms: uniforms, camera: planes) { commandBuffer, baked in
                self.enqueueVideoFrame(baked: baked, commandBuffer: commandBuffer, timestamp: frame.timestamp, forceKeyframe: forceKeyframe)
            }
            textureCache.flush()
            needsKeyframe = false
        } catch {
            Self.logger.error("相机纹理失败: \(String(describing: error))")
        }
    }

    /// 在烘焙命令缓冲里追加一次 blit，GPU 跑完再送编码器。bake 的回调与本方法同在 delegate 队列。
    private func enqueueVideoFrame(baked: MTLTexture, commandBuffer: MTLCommandBuffer, timestamp: TimeInterval, forceKeyframe: Bool) {
        guard let pool = pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer,
              let target = try? textureCache.texture(for: pixelBuffer, format: .bgra8Unorm),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "BakedToCallFrame"
        blit.copy(from: baked, to: target.texture)
        blit.endEncoding()
        // 补发时 GPU 早已写完这块缓冲，直接记下即可
        lastBakedPixelBuffer = pixelBuffer
        commandBuffer.addCompletedHandler { [encoder] _ in
            _ = target // 保持 IOSurface 到 blit 完成
            encoder.encode(pixelBuffer, timestamp: timestamp, forceKeyframe: forceKeyframe)
        }
    }

    private static func makePixelBufferPool(size: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size,
            kCVPixelBufferHeightKey: size,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        if status != kCVReturnSuccess {
            logger.error("像素缓冲池创建失败 \(status)")
        }
        return pool
    }

    // MARK: - 接收（MC 回调线程）

    private func receive(_ message: CallMessage) {
        switch message {
        case let .hello(deviceName, textureSize):
            report("对方 \(deviceName) · 贴图 \(textureSize)²")
        case let .topology(topology):
            let source = RemoteFaceMeshSource(rawTopology: topology)
            remote.withLock { $0 = source }
            DispatchQueue.main.async { [weak self] in self?.onRemoteSourceChange?(source) }
        case let .meshFrame(frame):
            statistics.meshReceived(timestamp: frame.timestamp)
            remote.withLock { $0 }?.update(frame: frame)
        case let .video(packet):
            statistics.videoReceived()
            decoder.decode(packet)
        case let .audio(packet):
            statistics.audioReceived()
            playout.enqueue(packet)
        }
    }

    private func report(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }
}
