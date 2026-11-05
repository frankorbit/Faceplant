import ARKit
import CoreVideo
import Foundation
import Metal
import os
import UIKit

/// 附近通话的数据流：本机脸 → 对端，对端 → 本机渲染。
///
/// 发送（ARSession delegate 队列）：
/// - 第一次拿到人脸就建烘焙器、发拓扑；
/// - 每帧原始顶点按 ≤ 30 fps 走不可靠信道；
/// - 烘焙贴图每隔一帧 blit 进像素缓冲，GPU 完成后交给 H.264 编码器，包走可靠信道；
/// - 麦克风样本原样打包走不可靠信道。
///
/// 接收（MC 回调线程）：拓扑 → 建 `RemoteFaceMeshSource`；顶点帧 → 更新；视频 → 解码器 → 贴图；音频 → 播放。
final class CallPipeline {
    static let textureSize = 512
    private static let meshSendInterval: TimeInterval = 1.0 / 31
    /// 烘焙每帧都做（预览用），编码隔一帧，60 fps 的脸追踪下视频就是 30 fps
    private static let videoFrameDivider = 2
    private static let videoBitrate = 1_500_000
    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "callPipeline")

    /// 对端的脸可以渲染了（nil 表示断开），主线程
    var onRemoteSourceChange: ((RemoteFaceMeshSource?) -> Void)?
    /// 一句状态，主线程
    var onStatus: ((String) -> Void)?
    /// 底部相机视图的尺寸，烘焙投影要和显示一致；主线程写，delegate 队列读
    let viewportSize = OSAllocatedUnfairLock(initialState: CGSize.zero)

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
    private var frameCounter = 0
    private var lastMeshSent: TimeInterval = 0
    private var pixelBufferPool: CVPixelBufferPool?

    init(device: MTLDevice, nearby: NearbySession, sessionController: ARSessionController) throws {
        self.device = device
        self.nearby = nearby
        self.sessionController = sessionController
        textureCache = try PixelBufferTextureCache(device: device)
        encoder = try VideoEncoder(width: Self.textureSize, height: Self.textureSize, bitrate: Self.videoBitrate, frameRate: 30)
        decoder = try VideoDecoder(device: device)
        pixelBufferPool = Self.makePixelBufferPool(size: Self.textureSize)
        bind()
    }

    func stop() {
        encoder.invalidate()
        playout.stop()
        remote.withLock { $0 = nil }
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
        sessionController.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
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

    private func handle(frame: ARFrame) {
        guard nearby.isConnected, let anchor = latestAnchor, anchor.isTracked, let baker, let capping else { return }
        let viewport = viewportSize.withLock { $0 }
        guard viewport.width > 0, viewport.height > 0 else { return }

        if !topologySent {
            nearby.send(.topology(capping.base), mode: .reliable)
            topologySent = true
        }
        let meshFrame = FaceMeshFrame(anchor: anchor, timestamp: frame.timestamp)
        if frame.timestamp - lastMeshSent >= Self.meshSendInterval {
            lastMeshSent = frame.timestamp
            nearby.send(.meshFrame(meshFrame), mode: .unreliable)
        }

        frameCounter += 1
        let encodeThisFrame = frameCounter % Self.videoFrameDivider == 0
        do {
            let planes = try textureCache.cameraPlanes(for: frame.capturedImage)
            let uniforms = ProjectionMath.bakeUniforms(
                frame: frame, anchorTransform: anchor.transform, orientation: .portrait, viewportSize: viewport
            )
            _ = baker.bake(vertices: capping.extend(meshFrame.vertices), uniforms: uniforms, camera: planes) { commandBuffer, baked in
                guard encodeThisFrame else { return }
                self.enqueueVideoFrame(baked: baked, commandBuffer: commandBuffer, timestamp: frame.timestamp)
            }
            textureCache.flush()
        } catch {
            Self.logger.error("相机纹理失败: \(String(describing: error))")
        }
    }

    /// 在烘焙命令缓冲里追加一次 blit，GPU 跑完再送编码器
    private func enqueueVideoFrame(baked: MTLTexture, commandBuffer: MTLCommandBuffer, timestamp: TimeInterval) {
        guard let pool = pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer,
              let target = try? textureCache.texture(for: pixelBuffer, format: .bgra8Unorm),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "BakedToCallFrame"
        blit.copy(from: baked, to: target.texture)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { [encoder] _ in
            _ = target // 保持 IOSurface 到 blit 完成
            encoder.encode(pixelBuffer, timestamp: timestamp)
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
            remote.withLock { $0 }?.update(frame: frame)
        case let .video(packet):
            decoder.decode(packet)
        case let .audio(packet):
            playout.enqueue(packet)
        }
    }

    private func report(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }
}
