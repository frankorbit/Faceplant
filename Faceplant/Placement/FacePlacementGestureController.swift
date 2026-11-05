import ARKit
import simd
import UIKit

/// 放置页摆放脸的手势：单指拖动沿墙面平移、双指旋转绕法线转、双指捏合缩放，三者可同时进行。
///
/// 手势只改 `adjustment`（见 `FaceAdjustment`），不动 anchor；每次变化通过 `onChange` 在主线程通知。
/// 脸还没放下时 `contextProvider` 返回 nil，手势被忽略。
final class FacePlacementGestureController: NSObject {
    /// 拖动换算需要的当前状态
    struct Context {
        let camera: ARCamera
        /// 脸所在 anchor 的世界变换（不含调整）
        let anchorTransform: simd_float4x4
    }

    var contextProvider: (() -> Context?)?
    var onChange: ((FaceAdjustment) -> Void)?

    private(set) var adjustment = FaceAdjustment.identity {
        didSet {
            if adjustment != oldValue {
                onChange?(adjustment)
            }
        }
    }

    private weak var view: UIView?
    private var panStartPoint: CGPoint?
    private var panStartTranslation = SIMD2<Float>(repeating: 0)
    private var rotationStart: Float = 0
    private var pinchStartScale: Float = 1

    func attach(to view: UIView) {
        self.view = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        for recognizer in [pan, rotation, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    /// 换了落点：平移、旋转归零，缩放保留，用户调好的大小不用再捏一次
    func resetPose() {
        adjustment.translation = .zero
        adjustment.rotation = 0
    }

    // MARK: - 手势

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            panStartPoint = point
            panStartTranslation = adjustment.translation
        case .changed:
            guard let start = panStartPoint, let context = contextProvider?() else { return }
            // 每次都从起点算总位移而不是累加增量，手指抖动不会累计误差
            guard let delta = FacePlacement.dragDelta(
                from: start, to: point, faceTransform: context.anchorTransform, camera: context.camera, viewSize: view.bounds.size
            ) else { return }
            adjustment.translation = panStartTranslation + delta
        case .ended, .cancelled, .failed:
            panStartPoint = nil
        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard contextProvider?() != nil else { return }
        switch gesture.state {
        case .began:
            rotationStart = adjustment.rotation
        case .changed:
            // UIKit 的旋转顺时针为正，脸的 +z 朝向观察者，绕 +z 的正角度在屏幕上是逆时针，取反让脸跟着手指转
            adjustment.rotation = rotationStart - Float(gesture.rotation)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard contextProvider?() != nil else { return }
        switch gesture.state {
        case .began:
            pinchStartScale = adjustment.scale
        case .changed:
            let scale = pinchStartScale * Float(gesture.scale)
            adjustment.scale = min(max(scale, FaceAdjustment.scaleRange.lowerBound), FaceAdjustment.scaleRange.upperBound)
        default:
            break
        }
    }
}

extension FacePlacementGestureController: UIGestureRecognizerDelegate {
    /// 旋转和捏合通常同时发生，拖动也允许叠加
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
