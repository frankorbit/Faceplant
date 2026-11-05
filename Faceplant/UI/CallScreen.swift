import SwiftUI

/// 附近通话页的 SwiftUI 壳。
struct CallScreen: View {
    var body: some View {
        CallView()
            .ignoresSafeArea()
            .navigationTitle("附近通话")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CallView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CallViewController {
        CallViewController()
    }

    func updateUIViewController(_ uiViewController: CallViewController, context: Context) {}
}
