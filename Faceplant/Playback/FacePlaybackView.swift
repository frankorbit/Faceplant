import Metal
import QuartzCore
import SceneKit
import UIKit

/// 用 SceneKit 展示一个 FaceMeshSource：每个显示周期拉一帧顶点与贴图重建几何。
///
/// M2 的 Metal 渲染器落地后，这个视图只保留给 Review 页做非 AR 预览。
final class FacePlaybackView: UIView {
    private let sceneView = SCNView()
    private let faceNode = SCNNode()
    private let material = SCNMaterial()
    private var displayLink: CADisplayLink?
    private var uvSource: SCNGeometrySource?
    private var element: SCNGeometryElement?

    var source: FaceMeshSource? {
        didSet { rebuildTopology() }
    }

    /// 每个显示周期在取帧之前调用，回放器用它拉新视频帧
    var onTick: ((CFTimeInterval) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.backgroundColor = .black
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = false
        sceneView.rendersContinuously = true
        addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let scene = SCNScene()
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        // 脸大约 0.15 米宽，放在 0.35 米外正好填满画面
        cameraNode.position = SCNVector3(0, 0, 0.35)
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(faceNode)
        sceneView.scene = scene

        material.lightingModel = .constant
        material.diffuse.contents = UIColor.darkGray
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func rebuildTopology() {
        guard let topology = source?.topology else {
            uvSource = nil
            element = nil
            faceNode.geometry = nil
            return
        }
        let uvData = topology.textureCoordinates.withUnsafeBufferPointer { Data(buffer: $0) }
        uvSource = SCNGeometrySource(
            data: uvData,
            semantic: .texcoord,
            vectorCount: topology.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        element = SCNGeometryElement(indices: topology.triangleIndices, primitiveType: .triangles)
    }

    @objc private func tick(_ link: CADisplayLink) {
        onTick?(link.targetTimestamp)
        guard let source, let uvSource, let element,
              let frame = source.currentFrame(at: link.targetTimestamp) else { return }

        let vertexData = frame.vertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: frame.vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let geometry = SCNGeometry(sources: [vertexSource, uvSource], elements: [element])
        if let texture = source.faceTexture {
            material.diffuse.contents = texture
        }
        geometry.materials = [material]
        faceNode.geometry = geometry
    }
}
