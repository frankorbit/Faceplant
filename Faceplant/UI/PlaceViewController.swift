import ARKit
import Metal
import UIKit

/// 放置页：后置摄像头世界追踪，已检测的平面画成网格，点击把录好的脸种上去，脸从墙里凸出并折射周围墙纹；
/// 放好后可以拖动、旋转、缩放微调，再把这个位置连同世界地图存成一条留言。
///
/// 职责划分：
/// - 生命周期与 UI：本类
/// - 会话：ARSessionController（世界追踪）
/// - 显示、放置与摆放手势：ARFacePlacementView
/// - 数据：FaceRecordingPlayer 作为 FaceMeshSource
/// - 留言落盘：FaceMessageCapture
final class PlaceViewController: UIViewController {
    private let recording: FaceRecording
    private let sessionController = ARSessionController()
    private let placementView = ARFacePlacementView()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let panel = ParameterPanel()
    private let panelButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)

    private var player: FaceRecordingPlayer?
    private var isSaving = false

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
        setupPlacementView()
        setupControls()
        setupRendering()
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
        placementView.isPaused = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        placementView.isPaused = true
        player?.pause()
        sessionController.pause()
    }

    // MARK: - Setup

    private func setupPlacementView() {
        placementView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placementView)
        NSLayoutConstraint.activate([
            placementView.topAnchor.constraint(equalTo: view.topAnchor),
            placementView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placementView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placementView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // 名字进世界地图，重访留言时按它找回
        placementView.anchorName = FaceMessage.anchorName
        placementView.onHint = { [weak self] hint in self?.hintLabel.text = hint }
        placementView.onStatus = { [weak self] status in self?.show(status: status) }
        placementView.onPlace = { [weak self] _ in self?.saveButton.isHidden = false }
    }

    private func setupControls() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(statusLabel)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.text = placementView.hints.scanning
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
        panel.onChange = { [weak self] parameters in self?.placementView.parameters = parameters }
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

    /// 半透明黑底白字的悬浮按钮样式，通话页也用
    static func overlayButtonConfiguration(title: String) -> UIButton.Configuration {
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
        do {
            let player = try FaceRecordingPlayer(recording: recording, device: device)
            try placementView.configure(device: device, sessionController: sessionController)
            placementView.source = player
            placementView.onDraw = { [weak player] hostTime in player?.pollTexture(hostTime: hostTime) }
            self.player = player
        } catch {
            show(status: "渲染初始化失败: \(error)")
        }
    }

    private func bindSession() {
        sessionController.onFrame = { [weak self] frame in
            self?.placementView.handle(frame: frame)
        }
        sessionController.onFailure = { [weak self] error in
            self?.show(status: "session failed: \(error.localizedDescription)")
        }
    }

    @objc private func togglePanel() {
        panel.isHidden.toggle()
    }

    /// 主线程
    private func show(status: String) {
        statusLabel.text = status
        statusLabel.isHidden = status.isEmpty
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
        guard let frame = sessionController.session.currentFrame, let transform = placementView.currentAnchorTransform(in: frame) else {
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
            frame: frame, faceTransform: transform, faceAdjustment: placementView.adjustment, recording: recording, title: title
        )
        FaceMessageCapture.save(request, session: sessionController.session) { [weak self] result in
            guard let self else { return }
            isSaving = false
            saveButton.isEnabled = true
            switch result {
            case .success:
                hintLabel.text = "已保存，首页「留言」里可以重访"
            case let .failure(error):
                hintLabel.text = placementView.hints.placed
                show(status: "\(error)")
            }
        }
    }
}
