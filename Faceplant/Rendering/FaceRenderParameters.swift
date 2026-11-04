import Foundation
import simd

/// 脸 pass 与墙面补丁 pass 的可调参数。拉伸相关的距离是脸局部 xy 平面上的椭圆归一化距离 d，
/// 椭圆半径由墙前顶点的包围盒决定（见 `FaceplantRenderer`），d = 1 大致是脸的轮廓。
struct FaceRenderParameters: Equatable {
    /// 额头、下巴方向沿外轮廓向内的淡出带宽度（米），带内从墙纹过渡到脸
    var edgeFade: Float = 0.02
    /// 两侧的淡出带是上下的多少倍。烘焙贴图两侧贴近耳朵的部分带着录制时的背景，要盖得更宽
    var sideFade: Float = 2
    /// 橡皮膜拉伸强度：墙纹采样点往脸中心拉的比例
    var warpStrength: Float = 0.3
    /// 拉伸衰减到零的距离，决定脸周围"被推开"的范围
    var warpOuter: Float = 2.0
    /// 过渡带里叠加的法线折射偏移，视口归一化单位
    var refractStrength: Float = 0.01
    /// z 方向缩放。ARKit 网格从鼻尖到轮廓有 6 到 8 cm 深，原版的面具明显更扁，
    /// 压到 0.6 倍时鼻尖离墙约 5 cm、额头和下巴离墙 1 到 2 cm，整张脸都在墙前
    var depthScale: Float = 0.6
    /// 把脸往墙里按的深度（米）。0 时整个外轮廓都在墙前、不被切，鼓包包住全部轮廓；
    /// 往里按会切掉贴近墙面的部分，切边随表情前后晃动会闪，一般不用
    var sinkDepth: Float = 0
    /// sinkDepth 为 0 时外轮廓最低点离墙的距离（米），整张脸整体抬高或贴近墙面
    var rimClearance: Float = 0.005
    /// 鼓包宽度与轮廓高度之比，越大鼓包越平缓
    var skirtSlope: Float = 2.5
    /// 烘焙贴图整体乘的亮度，脸比墙暗或亮时用它配
    var faceBrightness: Float = 1
    /// 录制页静态墙面上一张贴图铺多大（米）。砖墙贴图一行 6 块砖，1 米正好是 17 cm 一块；AR 场景不用
    var wallTileSize: Float = 1
    var faceTint = SIMD3<Float>(repeating: 1)

    static let standard = FaceRenderParameters()

    /// 调参面板展示的参数：标题、调大会看到什么、范围、显示单位
    struct Slider {
        let title: String
        let hint: String
        let range: ClosedRange<Float>
        let keyPath: WritableKeyPath<FaceRenderParameters, Float>
        /// 面板上显示的值 = 参数值 × displayScale，米制参数按厘米显示
        var displayScale: Float = 1
        var unit = ""

        /// 加减按钮每次变动显示值的 0.1
        var step: Float { 0.1 / displayScale }

        func format(_ value: Float) -> String {
            String(format: "%.1f%@", value * displayScale, unit)
        }
    }

    static let sliders: [Slider] = [
        Slider(title: "上下过渡", hint: "额头、下巴边缘有多宽一圈变成墙纹；调大脸露得少，边缘更柔", range: 0 ... 0.06, keyPath: \.edgeFade, displayScale: 100, unit: "cm"),
        Slider(title: "两侧过渡", hint: "两侧过渡带是上下的几倍；两侧露出录制时的背景就调大", range: 1 ... 4, keyPath: \.sideFade, unit: "×"),
        Slider(title: "墙纹推开", hint: "脸周围的墙纹被向外推开多少；0 不推，调大砖缝弯得更厉害", range: 0 ... 0.8, keyPath: \.warpStrength),
        Slider(title: "推开范围", hint: "墙纹被推开的范围是脸的几倍；调大影响的墙面更大", range: 1 ... 4, keyPath: \.warpOuter, unit: "×"),
        Slider(title: "边缘折射", hint: "过渡带里墙纹随起伏的弯曲；调大边缘更像玻璃，一般很小", range: 0 ... 0.1, keyPath: \.refractStrength, displayScale: 100),
        Slider(title: "脸的深度", hint: "鼻子凸出多少；1 是真人深度，调小脸更扁更贴墙，调大更立体", range: 0.2 ... 2, keyPath: \.depthScale, unit: "×"),
        Slider(title: "按进墙里", hint: "往墙里按几厘米；按进去的部分被切掉、边缘会闪，一般留 0", range: 0 ... 0.06, keyPath: \.sinkDepth, displayScale: 100, unit: "cm"),
        Slider(title: "轮廓离墙", hint: "脸的边缘离墙面几厘米；调大整张脸抬高，鼓包更高更宽", range: 0 ... 0.03, keyPath: \.rimClearance, displayScale: 100, unit: "cm"),
        Slider(title: "鼓包宽度", hint: "脸边缘到墙面的鼓包有多宽；调大坡更缓更自然，调小像一圈围墙", range: 0.5 ... 5, keyPath: \.skirtSlope, unit: "×"),
        Slider(title: "脸的亮度", hint: "脸的贴图整体变亮或变暗，和墙面配色用", range: 0.5 ... 1.5, keyPath: \.faceBrightness, unit: "×"),
        Slider(title: "墙纹大小", hint: "只影响录制页预览墙：一张贴图铺几米；调小砖块显得小、脸显得大", range: 0.3 ... 3, keyPath: \.wallTileSize, unit: "m"),
    ]
}
