import Foundation

/// 渲染层的编译期开关，方便在真机上对比效果。
enum FaceRenderOptions {
    /// 是否在眼洞后面画假眼球。洞口加盖后眼睛直接显示视频里的真眼睛，默认不画；
    /// v2 实时模式贴图按表情检索、视线与当下不一致时再打开。
    static let showsEyeballs = false
}
