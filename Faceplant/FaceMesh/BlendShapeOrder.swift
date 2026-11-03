import ARKit

/// 52 个 blendShape 在录制包里的固定顺序。
///
/// 这个顺序是文件格式的一部分，只能追加，不能调整或删除，否则旧录制包无法解析。
enum BlendShapeOrder {
    static let locations: [ARFaceAnchor.BlendShapeLocation] = [
        .browDownLeft, .browDownRight, .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
        .cheekPuff, .cheekSquintLeft, .cheekSquintRight,
        .eyeBlinkLeft, .eyeBlinkRight, .eyeLookDownLeft, .eyeLookDownRight, .eyeLookInLeft, .eyeLookInRight,
        .eyeLookOutLeft, .eyeLookOutRight, .eyeLookUpLeft, .eyeLookUpRight, .eyeSquintLeft, .eyeSquintRight,
        .eyeWideLeft, .eyeWideRight,
        .jawForward, .jawLeft, .jawOpen, .jawRight,
        .mouthClose, .mouthDimpleLeft, .mouthDimpleRight, .mouthFrownLeft, .mouthFrownRight, .mouthFunnel,
        .mouthLeft, .mouthLowerDownLeft, .mouthLowerDownRight, .mouthPressLeft, .mouthPressRight, .mouthPucker,
        .mouthRight, .mouthRollLower, .mouthRollUpper, .mouthShrugLower, .mouthShrugUpper,
        .mouthSmileLeft, .mouthSmileRight, .mouthStretchLeft, .mouthStretchRight, .mouthUpperUpLeft, .mouthUpperUpRight,
        .noseSneerLeft, .noseSneerRight,
        .tongueOut,
    ]

    static var count: Int { locations.count }

    static func vector(from blendShapes: [ARFaceAnchor.BlendShapeLocation: NSNumber]) -> [Float] {
        locations.map { blendShapes[$0]?.floatValue ?? 0 }
    }
}
