import ARKit
import Metal
import SceneKit
import UIKit

/// 附近通话页，上下分屏：
/// - 上半：对方的 3D 脸种在一面虚拟砖墙上（`WallPreviewView`，可拖动转角度）；
/// - 下半：自己的前置摄像头画面。
///
/// 职责划分：连接在 `NearbySession`，数据流在 `CallPipeline`，本类只管生命周期、布局和状态文字。
final class CallViewController: UIViewController {
    private let remoteView = WallPreviewView()
    private let sceneView = ARSCNView()
    private let sessionController = ARSessionController()
    private let nearby = NearbySession()
    private let statusLabel = UILabel()
    private let peerLabel = UILabel()
    private var pipeline: CallPipeline?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupViews()
        setupPipeline()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = sceneView.bounds.size
        pipeline?.viewportSize.withLock { $0 = size }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        remoteView.isPaused = false
        MicrophonePermission.request { [weak self] granted in
            guard let self, view.window != nil else { return }
            start(withAudio: granted)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        remoteView.isPaused = true
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

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(statusLabel)

        peerLabel.translatesAutoresizingMaskIntoConstraints = false
        peerLabel.font = .systemFont(ofSize: 15, weight: .medium)
        peerLabel.textColor = .white
        peerLabel.textAlignment = .center
        peerLabel.numberOfLines = 0
        peerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        peerLabel.layer.cornerRadius = 8
        peerLabel.clipsToBounds = true
        peerLabel.text = "正在找附近打开了这一页的人…"
        view.addSubview(peerLabel)

        NSLayoutConstraint.activate([
            remoteView.topAnchor.constraint(equalTo: view.topAnchor),
            remoteView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remoteView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
            sceneView.topAnchor.constraint(equalTo: remoteView.bottomAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            peerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            peerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            peerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            peerLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    private func setupPipeline() {
        guard let device = sceneView.device else {
            show(status: FaceplantError.metalUnavailable.description)
            return
        }
        do {
            try remoteView.configure(device: device)
            let pipeline = try CallPipeline(device: device, nearby: nearby, sessionController: sessionController)
            pipeline.onRemoteSourceChange = { [weak self] source in
                self?.remoteView.source = source
                if source != nil {
                    self?.show(status: "收到对方的脸")
                }
            }
            pipeline.onStatus = { [weak self] status in self?.show(status: status) }
            self.pipeline = pipeline
        } catch {
            show(status: "通话初始化失败: \(error)")
        }
        nearby.onStateChange = { [weak self] state in
            self?.pipeline?.handleConnection(state)
            self?.showPeer(state)
        }
        sessionController.onFailure = { [weak self] error in
            self?.show(status: "session failed: \(error.localizedDescription)")
        }
    }

    private func start(withAudio: Bool) {
        do {
            try AudioSessionConfigurator.activate(.call)
            try sessionController.runFaceTracking(providesAudio: withAudio)
            if !withAudio {
                show(status: "没有麦克风权限，只传脸不传声音")
            }
        } catch {
            show(status: "\(error)")
        }
        nearby.start()
    }

    // MARK: - 状态（主线程）

    private func showPeer(_ state: NearbySession.State) {
        peerLabel.text = switch state {
        case .idle: "已断开"
        case .searching: "正在找附近打开了这一页的人…"
        case let .connecting(name): "正在连接 \(name)…"
        case let .connected(name): "已连接 \(name)，对准前置摄像头"
        }
    }

    private func show(status: String) {
        statusLabel.text = status
        statusLabel.isHidden = status.isEmpty
    }
}
