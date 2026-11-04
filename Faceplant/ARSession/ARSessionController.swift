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
    /// 会话失败或中断，回主线程
    var onFailure: ((Error) -> Void)?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
    }

    func runFaceTracking() throws {
        guard ARFaceTrackingConfiguration.isSupported else { throw FaceplantError.faceTrackingUnsupported }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        configuration.maximumNumberOfTrackedFaces = 1
        // ARSCNView 接管 session 时可能改写 delegate，运行前再声明一次
        session.delegate = self
        session.delegateQueue = delegateQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// 后置摄像头世界追踪，检测竖直与水平平面，供放置页使用
    func runWorldTracking() throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw FaceplantError.worldTrackingUnsupported }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical, .horizontal]
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = false
        session.delegate = self
        session.delegateQueue = delegateQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
    }
}

extension ARSessionController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        onFaceAnchor?(face)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
}
