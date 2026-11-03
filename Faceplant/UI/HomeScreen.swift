import SwiftUI

/// 入口：录制新脸、已有录制列表、调试页。
struct HomeScreen: View {
    @State private var recordings: [FaceRecording] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        RecordScreen()
                    } label: {
                        Label("录制新脸", systemImage: "face.smiling")
                    }
                }

                Section("我的脸") {
                    if recordings.isEmpty {
                        Text("还没有录制。录一段 5 到 15 秒的脸，做几个夸张表情。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recordings) { recording in
                        NavigationLink {
                            ReviewScreen(recording: recording)
                        } label: {
                            RecordingRow(recording: recording)
                        }
                    }
                }

                Section("调试") {
                    NavigationLink("Spike A · 投影烘焙对齐") {
                        ProjectionSpikeView().ignoresSafeArea().navigationBarTitleDisplayMode(.inline)
                    }
                    NavigationLink("Spike B · 前后摄同开探针") {
                        DualCameraSpikeView().ignoresSafeArea().navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .navigationTitle("Faceplant")
            .onAppear(perform: reload)
            .alert("出错了", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func reload() {
        do {
            recordings = try FaceRecordingStore().list()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

private struct RecordingRow: View {
    let recording: FaceRecording

    var body: some View {
        HStack(spacing: 12) {
            if let image = UIImage(contentsOfFile: recording.thumbnailURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.manifest.createdAt, format: .dateTime.month().day().hour().minute())
                Text(String(format: "%.1f 秒 · %d 帧", recording.manifest.duration, recording.manifest.meshFrameCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
