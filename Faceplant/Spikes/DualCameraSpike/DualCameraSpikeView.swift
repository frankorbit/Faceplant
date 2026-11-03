import SwiftUI

struct DualCameraSpikeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DualCameraSpikeViewController {
        DualCameraSpikeViewController()
    }

    func updateUIViewController(_ uiViewController: DualCameraSpikeViewController, context: Context) {}
}
