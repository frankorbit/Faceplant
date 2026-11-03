import SwiftUI

/// 录制页的 SwiftUI 壳：录制完成后推到 Review 页。
struct RecordScreen: View {
    @State private var finished: FaceRecording?
    @State private var showReview = false

    var body: some View {
        RecordView { recording in
            finished = recording
            showReview = true
        }
        .ignoresSafeArea()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("录制")
        .navigationDestination(isPresented: $showReview) {
            if let finished {
                ReviewScreen(recording: finished)
            }
        }
    }
}

private struct RecordView: UIViewControllerRepresentable {
    let onFinish: (FaceRecording) -> Void

    func makeUIViewController(context: Context) -> RecordViewController {
        let controller = RecordViewController()
        controller.onFinish = onFinish
        return controller
    }

    func updateUIViewController(_ uiViewController: RecordViewController, context: Context) {
        uiViewController.onFinish = onFinish
    }
}
