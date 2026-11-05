import ARKit
import Metal
import MetalKit
import UIKit

/// 后置摄像头世界追踪里放一张脸的视图：MTKView + `FaceplantRenderer` 的 `.ar` 场景 + 平面网格 +
/// 点击放置 + 拖动/旋转/缩放微调。放置页用它放录好的脸，通话页用它放对方的脸，两边只差数据源和提示文案。
///
/// 会话由外部持有并运行；`handle(frame:)` 在会话的 delegate 队列调用，其余 API 与所有回调都在主线程。
final class ARFacePlacementView: UIView {
    /// 底部提示文案，按页面语境替换
    struct Hints {
        var scanning = "慢慢移动手机，扫描墙面或桌面"
        var planeFound = "检测到平面，点击网格放置你的脸"
        var placed = "拖动移位，双指旋转、缩放；再点一下换位置"
    }

    var hints = Hints()
    /// 放进 ARAnchor 的名字，留言要靠它从世界地图里找回；为 nil 则匿名
    var anchorName: String?

    /// 提示文案变化（主线程）
    var onHint: ((String) -> Void)?
    /// 追踪状态等一句话状态，空串表示正常（主线程）
    var onStatus: ((String) -> Void)?
    /// 脸放下或换了位置（主线程）
    var onPlace: ((ARAnchor) -> Void)?

    var source: FaceMeshSource? {
        didSet { renderer?.source = source }
    }

    var parameters = FaceRenderParameters.standard {
        didSet { renderer?.parameters = parameters }
    }

    /// 每次绘制开始时调用，回放器用它拉新视频帧
    var onDraw: ((CFTimeInterval) -> Void)? {
        didSet { renderer?.onDraw = onDraw }
    }

    var isPaused: Bool {
        get { metalView.isPaused }
        set { metalView.isPaused = newValue }
    }

    /// 脸所在的 anchor；为 nil 表示还没放
    private(set) var faceAnchor: ARAnchor?
    /// 手势对脸的局部调整
    var adjustment: FaceAdjustment { gestures.adjustment }

    private let metalView = MTKView()
    private let gestures = FacePlacementGestureController()
    private var renderer: FaceplantRenderer?
    private var sessionController: ARSessionController?
    // 以下两个只在 delegate 队列读写，用来节流提示的刷新
    private var lastTrackingDescription = ""
    private var lastHasPlane = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        backgroundColor = .black
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearDepth = 1
        metalView.preferredFramesPerSecond = 60
        metalView.framebufferOnly = true
        metalView.backgroundColor = .black
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        metalView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        gestures.attach(to: metalView)
        gestures.contextProvider = { [weak self] in
            guard let self, let frame = sessionController?.session.currentFrame, let transform = currentAnchorTransform(in: frame) else {
                return nil
            }
            return FacePlacementGestureController.Context(camera: frame.camera, anchorTransform: transform)
        }
        gestures.onChange = { [weak self] adjustment in
            self?.renderer?.faceAdjustment = adjustment.transform
        }
    }

    /// 创建渲染器并绑定会话。UIView 的 init 不能 throws，所以单独一步。
    func configure(device: MTLDevice, sessionController: ARSessionController) throws {
        self.sessionController = sessionController
        metalView.device = device
        let renderer = try FaceplantRenderer(
            device: device,
            scene: .ar(sessionController.session),
            colorPixelFormat: metalView.colorPixelFormat,
            depthPixelFormat: metalView.depthStencilPixelFormat
        )
        renderer.source = source
        renderer.parameters = parameters
        renderer.onDraw = onDraw
        // 脸放下之前把检测到的平面画出来，用户知道往哪点
        renderer.showsPlaneGrid = true
        metalView.delegate = renderer
        self.renderer = renderer
    }

    /// anchor 的变换会随追踪修正，取帧里的最新值
    func currentAnchorTransform(in frame: ARFrame) -> simd_float4x4? {
        guard let faceAnchor else { return nil }
        return frame.anchors.first { $0.identifier == faceAnchor.identifier }?.transform ?? faceAnchor.transform
    }

    /// 撤掉已放的脸，重新显示网格。会话重跑（配置变了）后 anchor 已不在，调用方要同步这一步。
    func clearPlacement() {
        if let faceAnchor {
            sessionController?.session.remove(anchor: faceAnchor)
        }
        faceAnchor = nil
        gestures.resetPose()
        renderer?.faceAnchorIdentifier = nil
        renderer?.showsPlaneGrid = true
        onHint?(lastHasPlane ? hints.planeFound : hints.scanning)
    }

    // MARK: - 放置

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let renderer, let sessionController, let frame = sessionController.session.currentFrame else { return }
        let point = gesture.location(in: metalView)
        let imagePoint = FacePlacement.imagePoint(fromViewPoint: point, viewSize: metalView.bounds.size, frame: frame)
        // 先用 estimatedPlane 保证点了就有反应；命中已检测的平面时结果里会带 ARPlaneAnchor，优先用它
        let query = frame.raycastQuery(from: imagePoint, allowing: .estimatedPlane, alignment: .any)
        let results = sessionController.session.raycast(query)
        guard let hit = results.first(where: { $0.anchor is ARPlaneAnchor }) ?? results.first else {
            onStatus?("没找到表面，对着有纹理的墙再试")
            return
        }

        let transform = FacePlacement.faceTransform(hit: hit, cameraTransform: frame.camera.transform)
        if let faceAnchor {
            sessionController.session.remove(anchor: faceAnchor)
        }
        let anchor = ARAnchor(name: anchorName ?? "face", transform: transform)
        sessionController.session.add(anchor: anchor)
        faceAnchor = anchor
        gestures.resetPose()
        renderer.faceAnchorIdentifier = anchor.identifier
        renderer.showsPlaneGrid = false
        onHint?(hints.placed)
        onStatus?(hit.anchor is ARPlaneAnchor ? "放在已检测的平面上" : "放在估计平面上，继续移动手机会更准")
        onPlace?(anchor)
    }

    // MARK: - 状态（delegate 队列）

    /// 由会话的 `onFrame` 转发进来，刷新追踪状态与平面提示
    func handle(frame: ARFrame) {
        let description = ARTrackingStatus.description(for: frame.camera.trackingState)
        if description != lastTrackingDescription {
            lastTrackingDescription = description
            DispatchQueue.main.async { [weak self] in self?.onStatus?(description) }
        }
        let hasPlane = frame.anchors.contains { $0 is ARPlaneAnchor }
        guard hasPlane != lastHasPlane else { return }
        lastHasPlane = hasPlane
        DispatchQueue.main.async { [weak self] in
            // 脸已经放下就不再改提示
            guard let self, faceAnchor == nil else { return }
            onHint?(hasPlane ? hints.planeFound : hints.scanning)
        }
    }
}
