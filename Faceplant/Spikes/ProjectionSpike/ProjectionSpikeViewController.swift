import ARKit
import SceneKit
import UIKit

/// Spike A：验证"相机画面投影到 canonical UV"的数学是否正确。
///
/// 验收标准：
/// 1. 主画面里贴着烘焙贴图的人脸网格，眼睛、鼻子、嘴与真人对齐，没有镜像或错位。
/// 2. 右下角的展开贴图是一张正立的脸。若倒置，用 Flip V 按钮切换并记录结论。
final class ProjectionSpikeViewController: UIViewController {
    private let sceneView = ARSCNView()
    private let previewView = SCNView()
    private let statusLabel = UILabel()
    private let flipButton = UIButton(type: .system)

    private var device: MTLDevice?
    private var textureCache: CameraTextureCache?
    private var baker: FaceTextureBaker?
    private var faceGeometry: ARSCNFaceGeometry?
    private var previewMaterial: SCNMaterial?
    private var latestFaceAnchor: ARFaceAnchor?
    private var flipV = false
    private var bakedFrameCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSceneView()
        setupPreview()
        setupHUD()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARFaceTrackingConfiguration.isSupported else {
            show(status: FaceplantError.faceTrackingUnsupported.description)
            return
        }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Setup

    private func setupSceneView() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.automaticallyUpdatesLighting = false
        sceneView.rendersCameraGrain = false
        sceneView.delegate = self
        sceneView.session.delegate = self
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        guard let device = sceneView.device else {
            show(status: FaceplantError.metalUnavailable.description)
            return
        }
        self.device = device
        do {
            textureCache = try CameraTextureCache(device: device)
        } catch {
            show(status: "\(error)")
        }
    }

    /// 右下角用一个正交相机 + SCNPlane 展示烘焙出来的展开贴图
    private func setupPreview() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .darkGray
        previewView.layer.borderColor = UIColor.white.cgColor
        previewView.layer.borderWidth = 1
        previewView.isPlaying = true
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.widthAnchor.constraint(equalToConstant: 160),
            previewView.heightAnchor.constraint(equalToConstant: 160),
            previewView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            previewView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        let scene = SCNScene()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 0.5
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 1)
        scene.rootNode.addChildNode(cameraNode)

        let plane = SCNPlane(width: 1, height: 1)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        plane.materials = [material]
        scene.rootNode.addChildNode(SCNNode(geometry: plane))
        previewMaterial = material
        previewView.scene = scene
    }

    private func setupHUD() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(statusLabel)

        flipButton.translatesAutoresizingMaskIntoConstraints = false
        flipButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        flipButton.tintColor = .white
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Flip V: off"
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        flipButton.configuration = configuration
        flipButton.addTarget(self, action: #selector(toggleFlip), for: .touchUpInside)
        view.addSubview(flipButton)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            flipButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            flipButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    @objc private func toggleFlip() {
        flipV.toggle()
        flipButton.configuration?.title = "Flip V: \(flipV ? "on" : "off")"
    }

    private func show(status: String) {
        statusLabel.text = status
    }

    // MARK: - Baking

    /// 每帧：取相机纹理，按当前 face anchor 烘焙，把结果同时贴到人脸网格和预览平面上
    private func bakeIfPossible(frame: ARFrame) {
        guard let anchor = latestFaceAnchor, anchor.isTracked,
              let baker, let textureCache else { return }

        let viewportSize = sceneView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        do {
            let planes = try textureCache.planes(for: frame.capturedImage)
            let uniforms = ProjectionMath.bakeUniforms(
                frame: frame,
                anchorTransform: anchor.transform,
                orientation: .portrait,
                viewportSize: viewportSize,
                flipV: flipV
            )
            let texture = baker.bake(vertices: Array(anchor.geometry.vertices), uniforms: uniforms, camera: planes)
            textureCache.flush()

            faceGeometry?.firstMaterial?.diffuse.contents = texture
            previewMaterial?.diffuse.contents = texture
            bakedFrameCount += 1
            if bakedFrameCount % 15 == 0 {
                let viewport = "\(Int(viewportSize.width))x\(Int(viewportSize.height))"
                show(status: "tracked · baked \(bakedFrameCount) · flipV \(flipV)\nviewport \(viewport)")
            }
        } catch {
            show(status: "bake failed: \(error)")
        }
    }
}

// MARK: - ARSCNViewDelegate

extension ProjectionSpikeViewController: ARSCNViewDelegate {
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let faceAnchor = anchor as? ARFaceAnchor, let device else { return nil }
        guard let geometry = ARSCNFaceGeometry(device: device) else { return nil }

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.lightGray
        geometry.materials = [material]
        faceGeometry = geometry

        // 拓扑只取一次；baker 创建失败要显示出来，不能静默
        if baker == nil {
            do {
                let topology = FaceMeshTopology(geometry: faceAnchor.geometry)
                baker = try FaceTextureBaker(device: device, topology: topology)
            } catch {
                DispatchQueue.main.async { [weak self] in self?.show(status: "baker init failed: \(error)") }
            }
        }
        return SCNNode(geometry: geometry)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let faceAnchor = anchor as? ARFaceAnchor else { return }
        faceGeometry?.update(from: faceAnchor.geometry)
    }
}

// MARK: - ARSessionDelegate

extension ProjectionSpikeViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        latestFaceAnchor = anchors.compactMap { $0 as? ARFaceAnchor }.first ?? latestFaceAnchor
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        bakeIfPossible(frame: frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        show(status: "session failed: \(error.localizedDescription)")
    }
}
