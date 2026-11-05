import ARKit
import Metal
import SceneKit
import UIKit

/// 附近通话页，两种显示模式：
/// - 虚拟墙（默认）上下分屏：上半对方的 3D 脸种在虚拟砖墙上（`WallPreviewView`，可拖动转角度），下半自己的前置画面；
/// - 真实平面：全屏后置摄像头世界追踪（`ARFacePlacementView`），点平面把对方的脸放上去，拖动、旋转、缩放微调。
///   此时前置摄像头只能顺带给出人脸几何（`userFaceTrackingEnabled`），自己的表情照常发出去，贴图停在切换前的最后一帧。
///
/// 职责划分：连接在 `NearbySession`，数据流在 `CallPipeline`，本类只管生命周期、布局、模式切换和状态文字。
final class CallViewController: UIViewController {
    enum Mode {
        case virtualWall
        case realSurface
    }

    private let remoteView = WallPreviewView()
    private let placementView = ARFacePlacementView()
    private let sceneView = ARSCNView()
    private let sessionController = ARSessionController()
    private let nearby = NearbySession()
    private let statusLabel = UILabel()
    private let statsLabel = UILabel()
    private let peerLabel = UILabel()
    private let hintLabel = UILabel()
    private let modeButton = UIButton(type: .system)
    private var pipeline: CallPipeline?
    private var mode = Mode.virtualWall
    private var audioGranted = false
    /// 最近一次连接状态，切模式后按它重写底部文字
    private var peerState = NearbySession.State.searching
    private var statsTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupViews()
        setupPipeline()
        applyMode()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = sceneView.bounds.size
        pipeline?.viewportSize.withLock { $0 = size }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyMode()
        MicrophonePermission.request { [weak self] granted in
            guard let self, view.window != nil else { return }
            audioGranted = granted
            start()
        }
        startStatistics()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statsTimer?.invalidate()
        statsTimer = nil
        remoteView.isPaused = true
        placementView.isPaused = true
        nearby.stop()
        pipeline?.stop()
        sessionController.pause()
    }

    // MARK: - Setup

    private func setupViews() {
        remoteView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(remoteView)

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.automaticallyUpdatesLighting = false
        sceneView.rendersCameraGrain = false
        sceneView.session = sessionController.session
        view.addSubview(sceneView)

        placementView.translatesAutoresizingMaskIntoConstraints = false
        placementView.hints.planeFound = "检测到平面，点击网格把对方的脸放上去"
        placementView.onHint = { [weak self] hint in self?.hintLabel.text = hint }
        placementView.onStatus = { [weak self] status in self?.show(status: status) }
        view.addSubview(placementView)

        for label in [statusLabel, statsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.font = .monospacedSystemFont(ofSize: label === statsLabel ? 11 : 12, weight: .regular)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            view.addSubview(label)
        }
        statsLabel.isHidden = true

        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
        view.addSubview(modeButton)

        for label in [peerLabel, hintLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            label.layer.cornerRadius = 8
            label.clipsToBounds = true
            view.addSubview(label)
        }
        peerLabel.text = "正在找附近打开了这一页的人…"
        hintLabel.text = placementView.hints.scanning
        activateConstraints()
    }

    private func activateConstraints() {
        NSLayoutConstraint.activate([
            remoteView.topAnchor.constraint(equalTo: view.topAnchor),
            remoteView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remoteView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
            sceneView.topAnchor.constraint(equalTo: remoteView.bottomAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            placementView.topAnchor.constraint(equalTo: view.topAnchor),
            placementView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placementView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placementView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -8),
            statsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            statsLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -8),
            modeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            modeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            peerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            peerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            peerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            peerLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: peerLabel.topAnchor, constant: -12),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    private func setupPipeline() {
        guard let device = sceneView.device else {
            show(status: FaceplantError.metalUnavailable.description)
            return
        }
        do {
            try remoteView.configure(device: device)
            try placementView.configure(device: device, sessionController: sessionController)
            let pipeline = try CallPipeline(device: device, nearby: nearby, sessionController: sessionController)
            pipeline.onRemoteSourceChange = { [weak self] source in
                self?.remoteView.source = source
                self?.placementView.source = source
                if source != nil {
                    self?.show(status: "收到对方的脸")
                }
            }
            pipeline.onStatus = { [weak self] status in self?.show(status: status) }
            self.pipeline = pipeline
        } catch {
            show(status: "通话初始化失败: \(error)")
        }
        sessionController.onFrame = { [weak self] frame in
            self?.pipeline?.handle(frame: frame)
            self?.placementView.handle(frame: frame)
        }
        nearby.onStateChange = { [weak self] state in
            self?.pipeline?.handleConnection(state)
            self?.showPeer(state)
        }
        sessionController.onFailure = { [weak self] error in
            self?.show(status: "session failed: \(error.localizedDescription)")
        }
    }

    private func start() {
        do {
            try AudioSessionConfigurator.activate(.call)
        } catch {
            show(status: "\(error)")
        }
        runSession()
        if !audioGranted {
            show(status: "没有麦克风权限，只传脸不传声音")
        }
        nearby.start()
    }

    // MARK: - 状态（主线程）

    private func showPeer(_ state: NearbySession.State) {
        peerState = state
        peerLabel.text = switch state {
        case .idle: "已断开"
        case .searching: "正在找附近打开了这一页的人…"
        case let .connecting(name): "正在连接 \(name)…"
        case let .connected(name): mode == .realSurface ? "已连接 \(name)" : "已连接 \(name)，对准前置摄像头"
        }
    }

    private func show(status: String) {
        statusLabel.text = status
        statusLabel.isHidden = status.isEmpty
    }
}

// MARK: - 模式切换

extension CallViewController {
    @objc private func toggleMode() {
        switchMode(to: mode == .virtualWall ? .realSurface : .virtualWall)
    }

    private func switchMode(to newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        // 重跑会话会清掉所有 anchor，放好的脸要一起撤
        placementView.clearPlacement()
        applyMode()
        runSession()
        showPeer(peerState)
    }

    /// 两套视图只显示一套并只让它绘制；离开页面时两边都停
    private func applyMode() {
        let realSurface = mode == .realSurface
        remoteView.isHidden = realSurface
        remoteView.isPaused = realSurface
        sceneView.isHidden = realSurface
        placementView.isHidden = !realSurface
        placementView.isPaused = !realSurface
        hintLabel.isHidden = !realSurface
        modeButton.configuration = PlaceViewController.overlayButtonConfiguration(title: realSurface ? "回到虚拟墙" : "放到真实平面")
        pipeline?.setSendsTexture(!realSurface)
    }

    /// 按当前模式运行会话：虚拟墙是前置人脸追踪；真实平面是后置世界追踪并顺带追踪用户的脸
    private func runSession() {
        do {
            switch mode {
            case .virtualWall:
                try sessionController.runFaceTracking(providesAudio: audioGranted, preferredFrameRate: CallPipeline.trackingFrameRate)
            case .realSurface:
                var options = ARSessionController.WorldTrackingOptions()
                options.tracksUserFace = true
                options.providesAudio = audioGranted
                options.preferredFrameRate = CallPipeline.trackingFrameRate
                try sessionController.runWorldTracking(options)
                if !ARSessionController.supportsUserFaceTracking {
                    show(status: "这台设备后置追踪时追不了你的脸，对方看到的表情会停住")
                }
            }
        } catch {
            show(status: "\(error)")
        }
    }
}

// MARK: - 测量

extension CallViewController {
    /// 每秒刷一次收发速率、丢帧、缓冲欠载和热状态，真机上定位"卡"在哪一段
    private func startStatistics() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let pipeline else { return }
            statsLabel.text = pipeline.statisticsSnapshot().description
            statsLabel.isHidden = !nearby.isConnected
        }
    }
}
