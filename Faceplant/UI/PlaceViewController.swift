import ARKit
import Metal
import MetalKit
import UIKit

/// 放置页：后置摄像头世界追踪，点击墙面把录好的脸种上去，脸从墙里凸出并折射周围墙纹。
///
/// 职责划分：
/// - 生命周期与 UI：本类
/// - 会话：ARSessionController（世界追踪）
/// - 绘制：FaceplantRenderer（MTKView 主线程回调）
/// - 数据：FaceRecordingPlayer 作为 FaceMeshSource
final class PlaceViewController: UIViewController {
    private let recording: FaceRecording
    private let sessionController = ARSessionController()
    private let metalView = MTKView()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let panel = ParameterPanel()
    private let panelButton = UIButton(type: .system)

    private var renderer: FaceplantRenderer?
    private var player: FaceRecordingPlayer?
    private var faceAnchor: ARAnchor?
    /// delegate 队列读写，用来节流追踪状态的刷新
    private var lastTrackingDescription = ""

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
        bindSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        do {
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
        hintLabel.text = "点击墙面放置你的脸"
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.textAlignment = .center
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        hintLabel.layer.cornerRadius = 8
        hintLabel.clipsToBounds = true
        view.addSubview(hintLabel)

        var config = UIButton.Configuration.filled()
        config.title = "调参"
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        panelButton.configuration = config
        panelButton.translatesAutoresizingMaskIntoConstraints = false
        panelButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        view.addSubview(panelButton)

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
            hintLabel.heightAnchor.constraint(equalToConstant: 36),
            hintLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
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
            renderer.onDraw = { [weak player] hostTime in player?.pollTexture(hostTime: hostTime) }
            metalView.delegate = renderer
            self.player = player
            self.renderer = renderer
        } catch {
            show(status: "渲染初始化失败: \(error)")
        }
    }

    private func bindSession() {
        sessionController.onFrame = { [weak self] frame in
            self?.updateTrackingStatus(frame.camera.trackingState)
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
        let anchor = ARAnchor(name: "face", transform: transform)
        sessionController.session.add(anchor: anchor)
        faceAnchor = anchor
        renderer.faceAnchorIdentifier = anchor.identifier
        hintLabel.text = "再点一下可以换位置"
        show(status: hit.anchor is ARPlaneAnchor ? "放在已检测的平面上" : "放在估计平面上，继续移动手机会更准")
    }

    @objc private func togglePanel() {
        panel.isHidden.toggle()
    }

    // MARK: - 状态

    /// delegate 队列
    private func updateTrackingStatus(_ state: ARCamera.TrackingState) {
        let description = switch state {
        case .normal: ""
        case .notAvailable: "追踪不可用"
        case let .limited(reason):
            switch reason {
            case .initializing: "初始化中，慢慢移动手机"
            case .excessiveMotion: "移动太快"
            case .insufficientFeatures: "特征不足，对着有纹理的墙"
            case .relocalizing: "重新定位中"
            @unknown default: "追踪受限"
            }
        }
        guard description != lastTrackingDescription else { return }
        lastTrackingDescription = description
        show(status: description)
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
