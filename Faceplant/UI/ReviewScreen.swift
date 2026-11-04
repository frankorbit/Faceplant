import Metal
import SwiftUI

/// Face Review：回放录好的脸，分享贴图视频，进入放置页，或删除。
struct ReviewScreen: View {
    let recording: FaceRecording

    @Environment(\.dismiss) private var dismiss
    @State private var player: FaceRecordingPlayer?
    @State private var isPlaying = false
    @State private var errorMessage: String?
    @State private var showPlacement = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackView(player: player)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f 秒 · %d 帧", recording.manifest.duration, recording.manifest.meshFrameCount))
                        Text("\(recording.manifest.textureSize)² 贴图 · \(recording.manifest.deviceModel)")
                        Text(recording.manifest.createdAt, style: .date)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Spacer()
                }

                Button(isPlaying ? "暂停" : "Start Playback") { togglePlayback() }
                    .buttonStyle(.borderedProminent)
                    .disabled(player == nil)

                ShareLink(item: recording.textureURL) {
                    Label("分享贴图视频", systemImage: "square.and.arrow.up")
                }

                Button("Make your face") { showPlacement = true }
                    .buttonStyle(.bordered)
                    .disabled(player == nil)

                Button("删除这段录制", role: .destructive) { deleteRecording() }
                    .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("Face Review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadPlayer)
        .onDisappear { player?.pause() }
        .navigationDestination(isPresented: $showPlacement) {
            PlaceScreen(recording: recording)
        }
        .alert("出错了", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(contentsOfFile: recording.thumbnailURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.3))
                .frame(width: 72, height: 72)
        }
    }

    private func loadPlayer() {
        guard player == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            errorMessage = FaceplantError.metalUnavailable.description
            return
        }
        do {
            let player = try FaceRecordingPlayer(recording: recording, device: device)
            self.player = player
            player.play()
            isPlaying = true
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = player.isPlaying
    }

    private func deleteRecording() {
        do {
            player?.pause()
            try FaceRecordingStore().delete(recording)
            dismiss()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

private struct PlaybackView: UIViewRepresentable {
    let player: FaceRecordingPlayer?

    func makeUIView(context: Context) -> FacePlaybackView {
        let view = FacePlaybackView()
        view.start()
        return view
    }

    func updateUIView(_ uiView: FacePlaybackView, context: Context) {
        guard uiView.source !== player else { return }
        uiView.source = player
        uiView.onTick = { [weak player] hostTime in player?.pollTexture(hostTime: hostTime) }
    }

    static func dismantleUIView(_ uiView: FacePlaybackView, coordinator: ()) {
        uiView.stop()
    }
}
