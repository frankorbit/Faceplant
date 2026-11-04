import Metal
import MetalKit
import UIKit

/// 录制页上半屏：一面静态墙上的实时效果。持有 MTKView、渲染器、墙面贴图与环绕相机，
/// 单指拖动转角度，双指捏合拉远拉近，双击复位。
///
/// 主线程使用。
final class WallPreviewView: UIView {
    /// 虚拟相机离墙的初始距离，脸约 0.2 米高，这个距离正好填满上半屏
    private static let initialDistance: Float = 0.5
    private static let distanceRange: ClosedRange<Float> = 0.2 ... 1.5

    private let metalView = MTKView()
    private var device: MTLDevice?
    private var renderer: FaceplantRenderer?
    private var wallTexture: MTLTexture?
    private var orbit = FaceplantRenderer.OrbitCamera(distance: WallPreviewView.initialDistance)
    private var orbitAtGestureStart = FaceplantRenderer.OrbitCamera(distance: WallPreviewView.initialDistance)

    var source: FaceMeshSource? {
        didSet { renderer?.source = source }
    }

    var parameters = FaceRenderParameters.standard {
        didSet { renderer?.parameters = parameters }
    }

    var isPaused: Bool {
        get { metalView.isPaused }
        set { metalView.isPaused = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearDepth = 1
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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

        metalView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(orbitPan(_:))))
        metalView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(orbitPinch(_:))))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(orbitReset))
        doubleTap.numberOfTapsRequired = 2
        metalView.addGestureRecognizer(doubleTap)
    }

    /// 创建渲染器与默认砖墙。UIView 的 init 不能 throws，所以单独一步。
    func configure(device: MTLDevice) throws {
        self.device = device
        metalView.device = device
        let wall = try BrickTexture.makeTexture(device: device)
        wallTexture = wall
        let renderer = try FaceplantRenderer(
            device: device,
            scene: .still(background: wall, camera: orbit),
            colorPixelFormat: metalView.colorPixelFormat,
            depthPixelFormat: metalView.depthStencilPixelFormat
        )
        renderer.source = source
        renderer.parameters = parameters
        metalView.delegate = renderer
        self.renderer = renderer
    }

    func setBackground(image: UIImage) throws {
        guard let device else { return }
        wallTexture = try BrickTexture.makeTexture(device: device, image: image)
        applyScene()
    }

    private func applyScene() {
        guard let wallTexture else { return }
        orbit.clamp(distanceRange: Self.distanceRange)
        renderer?.scene = .still(background: wallTexture, camera: orbit)
    }

    /// 单指拖动绕脸转角度，横向是 yaw，纵向是 pitch
    @objc private func orbitPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            orbitAtGestureStart = orbit
        }
        let translation = gesture.translation(in: metalView)
        orbit.yaw = orbitAtGestureStart.yaw + Float(translation.x) * 0.008
        orbit.pitch = orbitAtGestureStart.pitch + Float(translation.y) * 0.008
        applyScene()
    }

    @objc private func orbitPinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            orbitAtGestureStart = orbit
        }
        orbit.distance = orbitAtGestureStart.distance / Float(max(gesture.scale, 0.01))
        applyScene()
    }

    @objc private func orbitReset() {
        orbit = FaceplantRenderer.OrbitCamera(distance: Self.initialDistance)
        applyScene()
    }
}
