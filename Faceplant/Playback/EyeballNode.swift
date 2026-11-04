import SceneKit

/// SceneKit 假眼球：外层节点直接接收 `EyePose` 的变换，内层球体把贴图极点转向视线方向。
///
/// M2 的 Metal 渲染器会用同样的参数在 shader 里按法线角度画虹膜，不再依赖贴图。
enum EyeballNode {
    /// 两只眼共用一个材质，调用方创建一次传入。
    static func makeMaterial(style: EyeballStyle = .standard) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = style.makeTextureImage()
        return material
    }

    static func make(style: EyeballStyle = .standard, material: SCNMaterial) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(style.radius))
        sphere.segmentCount = 32
        sphere.materials = [material]

        // SCNSphere 贴图的 v=0 在 +y 极点；绕 x 轴转 +90° 把 +y 转到 +z，即 ARKit 眼球变换的视线方向
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.eulerAngles.x = .pi / 2

        let node = SCNNode()
        node.addChildNode(sphereNode)
        return node
    }
}
