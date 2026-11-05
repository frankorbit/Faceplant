import ARKit
import Foundation

/// 唯一持有 ARSession 的对象。delegate 回调跑在独立串行队列，避免主线程一忙就积压 ARFrame。
///
/// UI 不直接碰 ARSession；需要显示时把 `session` 交给 ARSCNView 或自家 Metal 视图。
final class ARSessionController: NSObject {
    let session = ARSession()
    let delegateQueue = DispatchQueue(label: "com.frank.faceplant.arsession", qos: .userInteractive)

    /// 以下回调都在 delegateQueue 上执行
    var onFrame: ((ARFrame) -> Void)?
    var onFaceAnchor: ((ARFaceAnchor) -> Void)?
    /// 会话新增 / 更新了 anchor：世界地图恢复出来的 anchor、识别到的参考图都从这里来
    var onAnchorsAdded: (([ARAnchor]) -> Void)?
    var onAnchorsUpdated: (([ARAnchor]) -> Void)?
    /// 麦克风采样，只在 `runFaceTracking(providesAudio: true)` 时有
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// 会话失败或中断，回主线程
    var onFailure: ((Error) -> Void)?

    /// 世界追踪的可选输入：重访留言时带上保存的地图与参考图；通话时顺带追踪用户的脸、采麦克风
    struct WorldTrackingOptions {
        var initialWorldMap: ARWorldMap?
        var detectionImages: Set<ARReferenceImage> = []
        /// 后置追踪的同时用前置摄像头给出 ARFaceAnchor（A12 及以上）。注意此时 capturedImage 是后置画面，烘焙不了脸的贴图
        var tracksUserFace = false
        var providesAudio = false
        /// 指定相机帧率（如 30），nil 用 ARKit 默认（通常 60）。通话时降到 30 省一半算力和发热
        var preferredFrameRate: Int?
    }

    /// 后置世界追踪时能否同时追踪用户的脸
    static var supportsUserFaceTracking: Bool { ARWorldTrackingConfiguration.supportsUserFaceTracking }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
    }

    /// - Parameters:
    ///   - providesAudio: 让 ARKit 顺带采集麦克风，样本和相机帧同一个时钟；需要麦克风权限
    ///   - preferredFrameRate: 指定相机帧率，nil 用默认。通话只要 512² 的贴图，选该帧率下分辨率最低的格式
    func runFaceTracking(providesAudio: Bool = false, preferredFrameRate: Int? = nil) throws {
        guard ARFaceTrackingConfiguration.isSupported else { throw FaceplantError.faceTrackingUnsupported }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.providesAudioData = providesAudio
        if let preferredFrameRate {
            let formats = ARFaceTrackingConfiguration.supportedVideoFormats
            if let format = Self.videoFormat(formats, frameRate: preferredFrameRate, lowestResolution: true) {
                configuration.videoFormat = format
            }
        }
        run(configuration)
    }

    /// 后置摄像头世界追踪，检测竖直与水平平面，供放置页与重访页使用
    func runWorldTracking(_ options: WorldTrackingOptions = WorldTrackingOptions()) throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw FaceplantError.worldTrackingUnsupported }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical, .horizontal]
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = false
        configuration.initialWorldMap = options.initialWorldMap
        configuration.userFaceTrackingEnabled = options.tracksUserFace && Self.supportsUserFaceTracking
        configuration.providesAudioData = options.providesAudio
        // 后置画面是全屏背景，帧率降了分辨率不降
        if let rate = options.preferredFrameRate {
            let formats = ARWorldTrackingConfiguration.supportedVideoFormats
            if let format = Self.videoFormat(formats, frameRate: rate, lowestResolution: false) {
                configuration.videoFormat = format
            }
        }
        if !options.detectionImages.isEmpty {
            configuration.detectionImages = options.detectionImages
            // 参考图贴在墙上不会动，持续追踪一张就够，识别到后 anchor 还能随视角修正
            configuration.maximumNumberOfTrackedImages = 1
        }
        run(configuration)
    }

    func pause() {
        session.pause()
    }

    /// 指定帧率的格式里选分辨率最低或最高的一个；该帧率不存在返回 nil，调用方沿用默认
    private static func videoFormat(
        _ formats: [ARConfiguration.VideoFormat], frameRate: Int, lowestResolution: Bool
    ) -> ARConfiguration.VideoFormat? {
        let candidates = formats.filter { $0.framesPerSecond == frameRate }
        return lowestResolution
            ? candidates.min { $0.imageResolution.width < $1.imageResolution.width }
            : candidates.max { $0.imageResolution.width < $1.imageResolution.width }
    }

    private func run(_ configuration: ARConfiguration) {
        // ARSCNView 接管 session 时可能改写 delegate，运行前再声明一次
        session.delegate = self
        session.delegateQueue = delegateQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
}

extension ARSessionController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        onAnchorsAdded?(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        onAnchorsUpdated?(anchors)
        guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        onFaceAnchor?(face)
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        onAudio?(audioSampleBuffer)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    /// 带着保存的地图重新运行时，中断后要继续尝试对齐旧地图而不是重开坐标系
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }
}
