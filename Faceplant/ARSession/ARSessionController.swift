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

    /// 世界追踪的可选输入：重访留言时带上保存的地图与参考图
    struct WorldTrackingOptions {
        var initialWorldMap: ARWorldMap?
        var detectionImages: Set<ARReferenceImage> = []
    }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
    }

    /// - Parameter providesAudio: 让 ARKit 顺带采集麦克风，样本和相机帧同一个时钟；需要麦克风权限
    func runFaceTracking(providesAudio: Bool = false) throws {
        guard ARFaceTrackingConfiguration.isSupported else { throw FaceplantError.faceTrackingUnsupported }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.providesAudioData = providesAudio
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
