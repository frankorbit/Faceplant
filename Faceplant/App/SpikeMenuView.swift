import SwiftUI

/// M0 阶段的入口：两个 spike 的菜单。正式产品流程落地后会被 FlowCoordinator 替换。
struct SpikeMenuView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("M0 Spikes") {
                    NavigationLink("A · 投影烘焙对齐验证") {
                        ProjectionSpikeView()
                            .ignoresSafeArea()
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    NavigationLink("B · 前后摄同开探针") {
                        DualCameraSpikeView()
                            .ignoresSafeArea()
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                Section("验收说明") {
                    Text("A：主画面人脸贴图五官对齐，右下角展开贴图为正立的脸。倒置则点 Flip V 并记录。")
                    Text("B：悬浮网格跟随表情；点 Start Front Probe 后看状态行是 running 还是 interrupted。")
                }
                .font(.footnote)
            }
            .navigationTitle("Faceplant")
        }
    }
}
