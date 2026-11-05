import ARKit
import Metal
import MetalKit
import simd
import UIKit

/// 重访一条留言：带着保存的世界地图和参考图重新开世界追踪，对上位置后脸从原来的墙面上顶出来并播放声音。
///
/// 两条定位路径同时跑：
/// - 世界地图重定位成功后，地图里的脸 anchor 直接可用，最准；
/// - 参考图先识别到时，用"脸相对参考图"的变换先把脸摆出来，地图一旦对上立刻切过去。
///
/// 地图里的 anchor 在重定位完成前就会出现，但坐标还是旧地图的，所以要等追踪状态变成 normal 再用。
final class MessageRevisitViewController: UIViewController {
    private static let imageDerivedAnchorName = "faceplant.message.fromImage"
    /// 参考图 anchor 位置变化小于这个值不重建脸 anchor
    private static let imageUpdateThreshold: Float = 0.01

    private let message: FaceMessage
    private let sessionController = ARSessionController()
    private let metalView = MTKView()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()

    private var renderer: FaceplantRenderer?
    private var player: FaceRecordingPlayer?

    // 以下只在 delegate 队列访问
    private var pendingMapAnchor: ARAnchor?
    private var mapAnchorAdopted = false
    private var imageDerivedAnchor: ARAnchor?
    private var lastTrackingDescription = ""

    init(message: FaceMessage) {
        self.message = message
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
        metalView.isPaused = false
        hintLabel.text = "正在读取留言…"
        // 世界地图有几 MB，解档放后台，读完再起会话
        let message = message
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Result {
                var options = ARSessionController.WorldTrackingOptions()
                options.initialWorldMap = try message.loadWorldMap()
                if let image = message.loadReferenceImage() {
                    options.detectionImages = [image]
                }
                return options
            }
            DispatchQueue.main.async { self?.startSession(with: loaded) }
        }
    }

    private func startSession(with loaded: Result<ARSessionController.WorldTrackingOptions, Error>) {
        guard view.window != nil else { return }
        do {
            let options = try loaded.get()
            try AudioSessionConfigurator.activate(.playback)
            try sessionController.runWorldTracking(options)
            hintLabel.text = options.initialWorldMap == nil ? "对准当初留言的那块墙" : "对准当初留言的墙面，慢慢移动手机"
        } catch {
            show(status: "\(error)")
        }
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
    }

    private func setupControls() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(statusLabel)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        hintLabel.layer.cornerRadius = 8
        hintLabel.clipsToBounds = true
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    private func setupRendering() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            show(status: FaceplantError.metalUnavailable.description)
            return
        }
        metalView.device = device
        do {
            let player = try FaceRecordingPlayer(recording: message.loadRecording(), device: device)
            let renderer = try FaceplantRenderer(
                device: device,
                scene: .ar(sessionController.session),
                colorPixelFormat: metalView.colorPixelFormat,
                depthPixelFormat: metalView.depthStencilPixelFormat
            )
            renderer.source = player
            // 放置时用手势调过的位置、角度、大小，叠回找回来的 anchor 上
            renderer.faceAdjustment = message.faceAdjustment
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
            self?.handle(frame: frame)
        }
        sessionController.onAnchorsAdded = { [weak self] anchors in
            self?.handle(anchors: anchors)
        }
        sessionController.onAnchorsUpdated = { [weak self] anchors in
            self?.handle(anchors: anchors)
        }
        sessionController.onFailure = { [weak self] error in
            self?.show(status: "session failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 定位（delegate 队列）

    private func handle(frame: ARFrame) {
        let description = ARTrackingStatus.description(for: frame.camera.trackingState)
        if description != lastTrackingDescription {
            lastTrackingDescription = description
            show(status: description)
        }
        // 地图 anchor 要等重定位完成（追踪恢复 normal）才在正确的位置
        if case .normal = frame.camera.trackingState, let anchor = pendingMapAnchor, !mapAnchorAdopted {
            adoptMapAnchor(anchor)
        }
    }

    private func handle(anchors: [ARAnchor]) {
        for anchor in anchors {
            if anchor.name == FaceMessage.anchorName {
                pendingMapAnchor = anchor
            } else if let imageAnchor = anchor as? ARImageAnchor {
                handle(imageAnchor: imageAnchor)
            }
        }
    }

    private func adoptMapAnchor(_ anchor: ARAnchor) {
        mapAnchorAdopted = true
        if let imageDerivedAnchor {
            sessionController.session.remove(anchor: imageDerivedAnchor)
            self.imageDerivedAnchor = nil
        }
        showFace(anchorIdentifier: anchor.identifier, hint: "找到了当初的位置")
    }

    /// 地图还没对上时，用参考图推出脸的位置；参考图 anchor 随视角修正时跟着挪
    private func handle(imageAnchor: ARImageAnchor) {
        guard !mapAnchorAdopted, imageAnchor.isTracked, let relative = message.faceRelativeToImage else { return }
        let transform = imageAnchor.transform * relative
        if let current = imageDerivedAnchor {
            let moved = simd_distance(current.transform.columns.3, transform.columns.3)
            guard moved > Self.imageUpdateThreshold else { return }
            sessionController.session.remove(anchor: current)
        }
        let anchor = ARAnchor(name: Self.imageDerivedAnchorName, transform: transform)
        sessionController.session.add(anchor: anchor)
        imageDerivedAnchor = anchor
        showFace(anchorIdentifier: anchor.identifier, hint: "按参考图找到了位置，地图对上后会更准")
    }

    private func showFace(anchorIdentifier: UUID, hint: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            renderer?.faceAnchorIdentifier = anchorIdentifier
            hintLabel.text = hint
            if player?.isPlaying == false {
                player?.play()
            }
        }
    }

    private func show(status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = status
            self?.statusLabel.isHidden = status.isEmpty
        }
    }
}
