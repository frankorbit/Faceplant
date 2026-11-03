import ARKit
import SceneKit
import UIKit

/// Spike B：世界追踪 + userFaceTrackingEnabled 下，人脸网格是否正常送达；
/// 以及再开一路前置 AVCaptureSession 能否拿到前置画面。
///
/// 验收标准：
/// 1. 屏幕前方悬浮的小人脸网格跟着你的表情动（证明 ARFaceAnchor 在世界追踪模式下可用）。
/// 2. 点 Start Probe 后，状态行给出明确结论：running 表示能拿到前置画面，interrupted / failed 表示不能。
final class DualCameraSpikeViewController: UIViewController {
    private let sceneView = ARSCNView()
    private let statusLabel = UILabel()
    private let probeButton = UIButton(type: .system)
    private let probe = FrontCameraProbe()

    private var floatingFaceNode: SCNNode?
    private var floatingFaceGeometry: ARSCNFaceGeometry?
    private var faceStatus = "face: waiting"
    private var probeStatus = "probe: idle"
    private var sessionStatus = "session: starting"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSceneView()
        setupHUD()
        probe.onStateChange = { [weak self] state in
            self?.probeStatus = "probe: \(state)"
            self?.refreshStatus()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical]
        if ARWorldTrackingConfiguration.supportsUserFaceTracking {
            configuration.userFaceTrackingEnabled = true
            sessionStatus = "session: world + userFaceTracking"
        } else {
            sessionStatus = "session: world only（设备不支持 userFaceTracking）"
        }
        refreshStatus()
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        probe.stop()
        sceneView.session.pause()
    }

    private func setupSceneView() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.automaticallyUpdatesLighting = true
        sceneView.session.delegate = self
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // 把人脸网格挂在相机前方 40 厘米，作为"表情是否送达"的可视化
        guard let device = sceneView.device, let geometry = ARSCNFaceGeometry(device: device, fillMesh: false) else {
            sessionStatus = "session: Metal 不可用"
            return
        }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemYellow
        material.fillMode = .lines
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        sceneView.scene.rootNode.addChildNode(node)
        floatingFaceNode = node
        floatingFaceGeometry = geometry
    }

    /// 每帧把网格放到相机前方 40 厘米。网格 +z 朝向脸的外侧，相机看向 -z，所以不需要额外旋转就正对观察者。
    private func updateFloatingFace(cameraTransform: simd_float4x4) {
        var offset = matrix_identity_float4x4
        offset.columns.3 = SIMD4<Float>(0, 0, -0.4, 1)
        floatingFaceNode?.simdTransform = cameraTransform * offset
    }

    private func setupHUD() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(statusLabel)

        probeButton.translatesAutoresizingMaskIntoConstraints = false
        probeButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        probeButton.tintColor = .white
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Start Front Probe"
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        probeButton.configuration = configuration
        probeButton.addTarget(self, action: #selector(startProbe), for: .touchUpInside)
        view.addSubview(probeButton)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            probeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            probeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    @objc private func startProbe() {
        probe.start()
    }

    private func refreshStatus() {
        statusLabel.text = [sessionStatus, faceStatus, probeStatus].joined(separator: "\n")
    }
}

extension DualCameraSpikeViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateFloatingFace(cameraTransform: frame.camera.transform)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        floatingFaceGeometry?.update(from: face.geometry)
        let jawOpen = face.blendShapes[.jawOpen]?.floatValue ?? 0
        faceStatus = String(format: "face: tracked %@ · jawOpen %.2f", face.isTracked ? "yes" : "no", jawOpen)
        refreshStatus()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        sessionStatus = "session: interrupted"
        refreshStatus()
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        sessionStatus = "session: interruption ended"
        refreshStatus()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionStatus = "session: failed \(error.localizedDescription)"
        refreshStatus()
    }
}
