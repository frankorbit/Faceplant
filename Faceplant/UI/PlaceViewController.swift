import ARKit
import Metal
import MetalKit
import UIKit

/// 放置页：后置摄像头世界追踪，已检测的平面画成网格，点击把录好的脸种上去，脸从墙里凸出并折射周围墙纹；
/// 放好后可以拖动、旋转、缩放微调，再把这个位置连同世界地图存成一条留言。
///
/// 职责划分：
/// - 生命周期与 UI：本类
/// - 会话：ARSessionController（世界追踪）
/// - 绘制：FaceplantRenderer（MTKView 主线程回调）
/// - 数据：FaceRecordingPlayer 作为 FaceMeshSource
/// - 摆放手势：FacePlacementGestureController，结果是 anchor 之上的 FaceAdjustment
/// - 留言落盘：FaceMessageCapture
final class PlaceViewController: UIViewController {
    private let recording: FaceRecording
    private let sessionController = ARSessionController()
    private let metalView = MTKView()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let panel = ParameterPanel()
    private let panelButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let gestures = FacePlacementGestureController()

    private var renderer: FaceplantRenderer?
    private var player: FaceRecordingPlayer?
    private var faceAnchor: ARAnchor?
    private var isSaving = false
    // 以下两个只在 delegate 队列读写，用来节流提示的刷新
    private var lastTrackingDescription = ""
    private var lastHasPlane = false

    init(recording: FaceRecording) {
        self.recording = recording
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupMetalView()
        setupControls()
        setupRendering()
        setupGestures()
        bindSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        do {
            try AudioSessionConfigurator.activate(.playback)
            try sessionController.runWorldTracking()
        } catch {
            show(status: "\(error)")
        }
        player?.play()
        metalView.isPaused = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        metalView.isPaused = true
        player?.pause()
        sessionController.pause()
    }

    // MARK: - Setup

    private func setupMetalView() {
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearDepth = 1
        metalView.preferredFramesPerSecond = 60
        metalView.framebufferOnly = true
        metalView.backgroundColor = .black
        view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        metalView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    private func setupControls() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(statusLabel)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.text = "慢慢移动手机，扫描墙面或桌面"
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        hintLabel.layer.cornerRadius = 8
        hintLabel.clipsToBounds = true
        view.addSubview(hintLabel)

        panelButton.configuration = Self.overlayButtonConfiguration(title: "调参")
        panelButton.translatesAutoresizingMaskIntoConstraints = false
        panelButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        view.addSubview(panelButton)

        saveButton.configuration = Self.overlayButtonConfiguration(title: "留言在这里")
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.isHidden = true
        saveButton.addTarget(self, action: #selector(saveMessageTapped), for: .touchUpInside)
        view.addSubview(saveButton)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        panel.onChange = { [weak self] parameters in self?.renderer?.parameters = parameters }
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: panelButton.leadingAnchor, constant: -8),
            panelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            panelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            panel.topAnchor.constraint(equalTo: panelButton.bottomAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            // 参数多了面板内部滚动，不盖住整屏
            panel.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.6),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            hintLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            saveButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            saveButton.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -12),
        ])
    }

    private static func overlayButtonConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        return config
    }

    private func setupRendering() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            show(status: FaceplantError.metalUnavailable.description)
            return
        }
        metalView.device = device
        do {
            let player = try FaceRecordingPlayer(recording: recording, device: device)
            let renderer = try FaceplantRenderer(
                device: device,
                scene: .ar(sessionController.session),
                colorPixelFormat: metalView.colorPixelFormat,
                depthPixelFormat: metalView.depthStencilPixelFormat
            )
            renderer.source = player
            // 脸放下之前把检测到的平面画出来，用户知道往哪点
            renderer.showsPlaneGrid = true
            renderer.onDraw = { [weak player] hostTime in player?.pollTexture(hostTime: hostTime) }
            metalView.delegate = renderer
            self.player = player
            self.renderer = renderer
        } catch {
            show(status: "渲染初始化失败: \(error)")
        }
    }

    private func setupGestures() {
        gestures.attach(to: metalView)
        gestures.contextProvider = { [weak self] in
            guard let self, let frame = sessionController.session.currentFrame, let transform = currentAnchorTransform(in: frame) else {
                return nil
            }
            return FacePlacementGestureController.Context(camera: frame.camera, anchorTransform: transform)
        }
        gestures.onChange = { [weak self] adjustment in
            self?.renderer?.faceAdjustment = adjustment.transform
        }
    }

    private func bindSession() {
        sessionController.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
        }
        sessionController.onFailure = { [weak self] error in
            self?.show(status: "session failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 放置

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let renderer, let frame = sessionController.session.currentFrame else { return }
        let point = gesture.location(in: metalView)
        let imagePoint = FacePlacement.imagePoint(fromViewPoint: point, viewSize: metalView.bounds.size, frame: frame)
        // 先用 estimatedPlane 保证点了就有反应；命中已检测的平面时结果里会带 ARPlaneAnchor，优先用它
        let query = frame.raycastQuery(from: imagePoint, allowing: .estimatedPlane, alignment: .any)
        let results = sessionController.session.raycast(query)
        guard let hit = results.first(where: { $0.anchor is ARPlaneAnchor }) ?? results.first else {
            show(status: "没找到表面，对着有纹理的墙再试")
            return
        }

        let transform = FacePlacement.faceTransform(hit: hit, cameraTransform: frame.camera.transform)
        if let faceAnchor {
            sessionController.session.remove(anchor: faceAnchor)
        }
        // 名字进世界地图，重访留言时按它找回
        let anchor = ARAnchor(name: FaceMessage.anchorName, transform: transform)
        sessionController.session.add(anchor: anchor)
        faceAnchor = anchor
        gestures.resetPose()
        renderer.faceAnchorIdentifier = anchor.identifier
        renderer.showsPlaneGrid = false
        saveButton.isHidden = false
        hintLabel.text = "拖动移位，双指旋转、缩放；再点一下换位置"
        show(status: hit.anchor is ARPlaneAnchor ? "放在已检测的平面上" : "放在估计平面上，继续移动手机会更准")
    }

    /// anchor 的变换会随追踪修正，取帧里的最新值；主线程
    private func currentAnchorTransform(in frame: ARFrame) -> simd_float4x4? {
        guard let faceAnchor else { return nil }
        return frame.anchors.first { $0.identifier == faceAnchor.identifier }?.transform ?? faceAnchor.transform
    }

    @objc private func togglePanel() {
        panel.isHidden.toggle()
    }

    // MARK: - 状态（delegate 队列）

    private func handle(frame: ARFrame) {
        let description = ARTrackingStatus.description(for: frame.camera.trackingState)
        if description != lastTrackingDescription {
            lastTrackingDescription = description
            show(status: description)
        }
        let hasPlane = frame.anchors.contains { $0 is ARPlaneAnchor }
        guard hasPlane != lastHasPlane else { return }
        lastHasPlane = hasPlane
        DispatchQueue.main.async { [weak self] in
            // 脸已经放下就不再改提示
            guard let self, faceAnchor == nil else { return }
            hintLabel.text = hasPlane ? "检测到平面，点击网格放置你的脸" : "慢慢移动手机，扫描墙面或桌面"
        }
    }

    private func show(status: String) {
        if Thread.isMainThread {
            statusLabel.text = status
            statusLabel.isHidden = status.isEmpty
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = status
                self?.statusLabel.isHidden = status.isEmpty
            }
        }
    }
}

// MARK: - 留言

extension PlaceViewController {
    @objc private func saveMessageTapped() {
        guard !isSaving else { return }
        let alert = UIAlertController(title: "留言在这里", message: "给这条留言起个名字（可不填）", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "比如：门口" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.saveMessage(title: title)
        })
        present(alert, animated: true)
    }

    private func saveMessage(title: String) {
        guard let frame = sessionController.session.currentFrame, let transform = currentAnchorTransform(in: frame) else {
            show(status: "先点墙面放好脸再留言")
            return
        }
        if frame.worldMappingStatus == .notAvailable || frame.worldMappingStatus == .limited {
            show(status: "周围地图还没建好，保存后重访可能对不上；环视一圈再保存更稳")
        }
        isSaving = true
        saveButton.isEnabled = false
        hintLabel.text = "正在保存留言…"
        let request = FaceMessageCapture.Request(
            frame: frame, faceTransform: transform, faceAdjustment: gestures.adjustment, recording: recording, title: title
        )
        FaceMessageCapture.save(request, session: sessionController.session) { [weak self] result in
            guard let self else { return }
            isSaving = false
            saveButton.isEnabled = true
            switch result {
            case .success:
                hintLabel.text = "已保存，首页「留言」里可以重访"
            case let .failure(error):
                hintLabel.text = "拖动移位，双指旋转、缩放；再点一下换位置"
                show(status: "\(error)")
            }
        }
    }
}
