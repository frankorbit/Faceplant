import ARKit
import Metal
import os
import PhotosUI
import SceneKit
import UIKit

/// 录制页，和原版一样上下分屏：
/// - 上半：静态墙面上的实时效果（`FaceplantRenderer` 的 still 场景，默认程序生成的砖墙，可换相册里的照片），
///   和放置页走同一套 shader，调参面板两边共用，不用录一段再去墙上看。
/// - 下半：前置摄像头画面叠加烘焙贴图后的网格，按钮开始/停止录制。
///
/// 职责划分：
/// - 生命周期与 UI：本类
/// - 会话：ARSessionController（独立 delegate 队列）
/// - 每帧烘焙与录制：`handle(frame:)`，在 delegate 队列执行
/// - 下半显示：ARSCNView，脸节点的几何由 `LiveFaceMeshSource` 的最新帧（含加盖）在渲染线程重建
final class RecordViewController: UIViewController {
    var onFinish: ((FaceRecording) -> Void)?

    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "record")
    private static let textureSize = 1024
    private let previewView = WallPreviewView()
    private let sceneView = ARSCNView()
    private let sessionController = ARSessionController()
    private let recordButton = UIButton(type: .custom)
    private let timerLabel = UILabel()
    private let statusLabel = UILabel()
    private let panel = ParameterPanel()
    private let panelButton = UIButton(type: .system)
    private let backgroundButton = UIButton(type: .system)

    private var device: MTLDevice?
    private var textureCache: PixelBufferTextureCache?
    private let viewportSize = OSAllocatedUnfairLock(initialState: CGSize.zero)

    /// 下半预览几何与数据源。delegate 队列写一次，SceneKit 渲染线程每帧读。
    private struct Preview {
        let geometry: SceneKitFaceGeometry
        let source: LiveFaceMeshSource
    }

    private let preview = OSAllocatedUnfairLock<Preview?>(initialState: nil)
    /// 只在渲染线程与主线程改 diffuse，SceneKit 对材质属性的赋值是线程安全的
    private let previewMaterial = SCNMaterial()
    private let eyeMaterial = EyeballNode.makeMaterial()
    // 以下只在 SceneKit 渲染线程（ARSCNViewDelegate 回调）访问
    private var leftEyeNode: SCNNode?
    private var rightEyeNode: SCNNode?

    // 以下只在 delegate 队列访问
    private var latestAnchor: ARFaceAnchor?
    private var baker: FaceTextureBaker?
    private var capping: FaceMeshCapping?
    private var liveSource: LiveFaceMeshSource?
    private var recorder: FaceRecorder?

    /// 以下主线程
    private var isRecording = false
    /// 麦克风授权结果；拒绝时照常录脸，只是没有声音
    private var microphoneGranted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupViews()
        setupControls()
        setupRendering()
        bindSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = sceneView.bounds.size
        viewportSize.withLock { $0 = size }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        previewView.isPaused = false
        // 先问麦克风再起会话：providesAudioData 在没授权时拿不到声音，之后也不会补
        MicrophonePermission.request { [weak self] granted in
            guard let self, view.window != nil else { return }
            microphoneGranted = granted
            startSession(withAudio: granted)
        }
    }

    private func startSession(withAudio: Bool) {
        do {
            if withAudio {
                try AudioSessionConfigurator.activate(.recording)
            }
            try sessionController.runFaceTracking(providesAudio: withAudio)
            show(status: withAudio ? "对准前置摄像头" : "没有麦克风权限，只录脸不录声音")
        } catch {
            show(status: "\(error)")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        previewView.isPaused = true
        sessionController.delegateQueue.async { [weak self] in
            self?.recorder?.discard()
            self?.recorder = nil
        }
        sessionController.pause()
    }

    // MARK: - Setup

    private func setupViews() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.automaticallyUpdatesLighting = false
        sceneView.rendersCameraGrain = false
        sceneView.session = sessionController.session
        sceneView.delegate = self
        view.addSubview(sceneView)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
            sceneView.topAnchor.constraint(equalTo: previewView.bottomAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        previewMaterial.lightingModel = .constant
        previewMaterial.diffuse.contents = UIColor.lightGray

        guard let device = sceneView.device else {
            show(status: FaceplantError.metalUnavailable.description)
            return
        }
        self.device = device
        do {
            textureCache = try PixelBufferTextureCache(device: device)
        } catch {
            show(status: "\(error)")
        }
    }

    private func setupRendering() {
        guard let device else { return }
        do {
            try previewView.configure(device: device)
        } catch {
            show(status: "预览初始化失败: \(error)")
        }
    }

    private func bindSession() {
        sessionController.onFaceAnchor = { [weak self] anchor in
            self?.latestAnchor = anchor
            self?.prepareBakerIfNeeded(anchor: anchor)
        }
        sessionController.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
        }
        sessionController.onAudio = { [weak self] sampleBuffer in
            self?.recorder?.appendAudio(sampleBuffer)
        }
        sessionController.onFailure = { [weak self] error in
            self?.show(status: "session failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Per-frame (delegate queue)

    private func prepareBakerIfNeeded(anchor: ARFaceAnchor) {
        guard baker == nil, let device else { return }
        // 烘焙与预览都用加盖后的拓扑，录制包里写的仍是 ARKit 原始拓扑
        let capping = FaceMeshCapping(base: FaceMeshTopology(geometry: anchor.geometry))
        do {
            let baker = try FaceTextureBaker(device: device, topology: capping.topology, textureSize: Self.textureSize)
            let liveSource = LiveFaceMeshSource(topology: capping.topology)
            self.baker = baker
            self.capping = capping
            self.liveSource = liveSource
            preview.withLock { $0 = Preview(geometry: SceneKitFaceGeometry(topology: capping.topology), source: liveSource) }
            DispatchQueue.main.async { [weak self] in self?.previewView.source = liveSource }
        } catch {
            show(status: "baker init failed: \(error)")
        }
    }

    private func handle(frame: ARFrame) {
        guard let anchor = latestAnchor, anchor.isTracked,
              let baker, let capping, let textureCache, let liveSource else { return }
        let viewport = viewportSize.withLock { $0 }
        guard viewport.width > 0, viewport.height > 0 else { return }

        // 录制写原始帧，烘焙与预览用加盖后的帧
        let meshFrame = FaceMeshFrame(anchor: anchor, timestamp: frame.timestamp)
        let cappedFrame = capping.extend(meshFrame)
        do {
            let planes = try textureCache.cameraPlanes(for: frame.capturedImage)
            let uniforms = ProjectionMath.bakeUniforms(
                frame: frame, anchorTransform: anchor.transform, orientation: .portrait, viewportSize: viewport
            )
            let recorder = recorder
            var captureError: Error?
            let texture = baker.bake(vertices: cappedFrame.vertices, uniforms: uniforms, camera: planes) { commandBuffer, baked in
                guard let recorder else { return }
                do {
                    try recorder.capture(frame: meshFrame, baked: baked, commandBuffer: commandBuffer)
                } catch {
                    captureError = error
                }
            }
            textureCache.flush()
            liveSource.update(frame: cappedFrame, texture: texture)

            let elapsed = recorder?.elapsed
            DispatchQueue.main.async { [weak self] in
                self?.previewMaterial.diffuse.contents = texture
                if let elapsed {
                    self?.timerLabel.text = String(format: "%04.1f", elapsed)
                }
            }
            if let captureError {
                throw captureError
            }
            if let recorder, recorder.elapsed >= FaceRecorder.maxDuration {
                stopRecording()
            }
        } catch {
            Self.logger.error("帧处理失败: \(String(describing: error))")
            show(status: "录制出错: \(error)")
            recorder?.discard()
            recorder = nil
            DispatchQueue.main.async { [weak self] in self?.setRecordingUI(false) }
        }
    }

    // MARK: - Recording control

    @objc private func toggleRecording() {
        if isRecording {
            sessionController.delegateQueue.async { [weak self] in self?.stopRecording() }
        } else {
            setRecordingUI(true)
            let withAudio = microphoneGranted
            sessionController.delegateQueue.async { [weak self] in self?.startRecording(withAudio: withAudio) }
        }
    }

    /// delegate 队列
    private func startRecording(withAudio: Bool) {
        guard recorder == nil, let baker, let capping, let textureCache else {
            show(status: "还没检测到人脸，稍等再按")
            DispatchQueue.main.async { [weak self] in self?.setRecordingUI(false) }
            return
        }
        do {
            let store = try FaceRecordingStore()
            recorder = try FaceRecorder(
                packageURL: store.makePackageURL(),
                topology: capping.base,
                textureSize: baker.textureSize,
                textureCache: textureCache,
                includesAudio: withAudio
            )
            show(status: withAudio ? "录制中，说句话、做几个夸张表情" : "录制中，做几个夸张表情")
        } catch {
            show(status: "无法开始录制: \(error)")
            DispatchQueue.main.async { [weak self] in self?.setRecordingUI(false) }
        }
    }

    /// delegate 队列
    private func stopRecording() {
        guard let recorder else { return }
        self.recorder = nil
        show(status: "正在保存…")
        recorder.finish { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setRecordingUI(false)
                switch result {
                case let .success(recording):
                    self.show(status: "已保存")
                    self.onFinish?(recording)
                case let .failure(error):
                    self.show(status: "保存失败: \(error)")
                }
            }
        }
    }

    // MARK: - UI helpers (main)

    private func setRecordingUI(_ recording: Bool) {
        isRecording = recording
        recordButton.backgroundColor = recording ? .white : .systemRed
        recordButton.layer.borderColor = recording ? UIColor.systemRed.cgColor : UIColor.white.cgColor
        recordButton.accessibilityLabel = recording ? "停止录制" : "开始录制"
        if !recording {
            timerLabel.text = "00.0"
        }
    }

    private func show(status: String) {
        if Thread.isMainThread {
            statusLabel.text = status
        } else {
            DispatchQueue.main.async { [weak self] in self?.statusLabel.text = status }
        }
    }
}

// MARK: - PHPickerViewControllerDelegate

extension RecordViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            DispatchQueue.main.async {
                if let image = object as? UIImage {
                    self?.applyBackground(image)
                } else if let error {
                    self?.show(status: "读取照片失败: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - ARSCNViewDelegate（SceneKit 渲染线程）

extension RecordViewController: ARSCNViewDelegate {
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard anchor is ARFaceAnchor else { return nil }
        let node = SCNNode()
        if FaceRenderOptions.showsEyeballs {
            let leftEye = EyeballNode.make(material: eyeMaterial)
            let rightEye = EyeballNode.make(material: eyeMaterial)
            node.addChildNode(leftEye)
            node.addChildNode(rightEye)
            leftEyeNode = leftEye
            rightEyeNode = rightEye
        }
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let faceAnchor = anchor as? ARFaceAnchor else { return }
        let preview = preview.withLock { $0 }
        let frame = preview?.source.currentFrame(at: 0)
        if let preview, let frame, let geometry = preview.geometry.makeGeometry(vertices: frame.vertices, material: previewMaterial) {
            node.geometry = geometry
        }
        leftEyeNode?.simdTransform = faceAnchor.leftEyeTransform
        rightEyeNode?.simdTransform = faceAnchor.rightEyeTransform
    }
}

// MARK: - 控件搭建与预览控制（主线程）

private extension RecordViewController {
    func setupControls() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(statusLabel)

        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        timerLabel.textColor = .white
        timerLabel.text = "00.0"
        view.addSubview(timerLabel)

        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.backgroundColor = .systemRed
        recordButton.layer.cornerRadius = 36
        recordButton.layer.borderWidth = 4
        recordButton.layer.borderColor = UIColor.white.cgColor
        recordButton.accessibilityLabel = "开始录制"
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        view.addSubview(recordButton)

        panelButton.configuration = Self.overlayButtonConfiguration(title: "调参")
        panelButton.translatesAutoresizingMaskIntoConstraints = false
        panelButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        view.addSubview(panelButton)

        backgroundButton.configuration = Self.overlayButtonConfiguration(title: "换墙")
        backgroundButton.translatesAutoresizingMaskIntoConstraints = false
        backgroundButton.addTarget(self, action: #selector(pickBackground), for: .touchUpInside)
        view.addSubview(backgroundButton)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        panel.onChange = { [weak self] parameters in self?.previewView.parameters = parameters }
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: backgroundButton.leadingAnchor, constant: -8),
            panelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            panelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            backgroundButton.topAnchor.constraint(equalTo: panelButton.topAnchor),
            backgroundButton.trailingAnchor.constraint(equalTo: panelButton.leadingAnchor, constant: -8),
            panel.topAnchor.constraint(equalTo: panelButton.bottomAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            // 参数多了面板内部滚动，不盖住整屏
            panel.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.6),
            recordButton.widthAnchor.constraint(equalToConstant: 72),
            recordButton.heightAnchor.constraint(equalToConstant: 72),
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            timerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            timerLabel.bottomAnchor.constraint(equalTo: recordButton.topAnchor, constant: -12),
        ])
    }

    static func overlayButtonConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        return config
    }

    // MARK: - 预览控制（主线程）

    @objc func togglePanel() {
        panel.isHidden.toggle()
    }

    @objc func pickBackground() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func applyBackground(_ image: UIImage) {
        do {
            try previewView.setBackground(image: image)
        } catch {
            show(status: "换墙失败: \(error)")
        }
    }
}
