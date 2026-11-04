import UIKit

/// 假眼球的外观参数与贴图生成。
///
/// 贴图按球面经纬展开：图像顶部对应球的 +y 极点，瞳孔、虹膜、巩膜是绕极点的同心带，
/// 所以画成水平条带即可。节点装配时把 +y 极点转到视线方向（+z），见 `EyeballNode`。
struct EyeballStyle {
    /// 眼球半径，米。真人约 12 mm；ARKit 眼球变换原点在眼球中心，半径过大会从眼皮里凸出来
    var radius: Float = 0.0115
    /// 虹膜的角半径，弧度。虹膜直径约 11.5 mm 对应 30°
    var irisAngularRadius: Float = .pi / 6
    /// 瞳孔的角半径，弧度
    var pupilAngularRadius: Float = .pi / 18
    var irisColor = UIColor(red: 0.36, green: 0.24, blue: 0.15, alpha: 1)
    var irisRimColor = UIColor(red: 0.16, green: 0.10, blue: 0.06, alpha: 1)
    var scleraColor = UIColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)

    static let standard = EyeballStyle()

    /// 生成经纬展开贴图。宽度只影响水平方向，条带是均匀的，所以宽度给小一点即可。
    func makeTextureImage(size: CGSize = CGSize(width: 64, height: 512)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            let height = size.height
            // 纬度角 0..π 线性映射到 v 0..1，再乘高度
            let irisBottom = CGFloat(irisAngularRadius / .pi) * height
            let pupilBottom = CGFloat(pupilAngularRadius / .pi) * height

            cg.setFillColor(scleraColor.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            // 虹膜：中心亮、边缘暗的径向渐变，在展开图里就是从上到下的线性渐变
            let colors = [irisColor.cgColor, irisColor.cgColor, irisRimColor.cgColor] as CFArray
            let locations: [CGFloat] = [0, 0.55, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                cg.saveGState()
                cg.clip(to: CGRect(x: 0, y: 0, width: size.width, height: irisBottom))
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: irisBottom), options: [])
                cg.restoreGState()
            }

            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: pupilBottom))
        }
    }
}
