import ARKit

/// 把追踪状态翻成给用户看的一句话，放置页与重访页共用。正常追踪返回空串。
enum ARTrackingStatus {
    static func description(for state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: ""
        case .notAvailable: "追踪不可用"
        case let .limited(reason):
            switch reason {
            case .initializing: "初始化中，慢慢移动手机"
            case .excessiveMotion: "移动太快"
            case .insufficientFeatures: "特征不足，对着有纹理的墙"
            case .relocalizing: "重新定位中，对准当初的位置"
            @unknown default: "追踪受限"
            }
        }
    }
}
