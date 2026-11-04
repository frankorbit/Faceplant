import SwiftUI

/// 放置页的 SwiftUI 壳。
struct PlaceScreen: View {
    let recording: FaceRecording

    var body: some View {
        PlaceView(recording: recording)
            .ignoresSafeArea()
            .navigationTitle("Make your face")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaceView: UIViewControllerRepresentable {
    let recording: FaceRecording

    func makeUIViewController(context: Context) -> PlaceViewController {
        PlaceViewController(recording: recording)
    }

    func updateUIViewController(_ uiViewController: PlaceViewController, context: Context) {}
}
