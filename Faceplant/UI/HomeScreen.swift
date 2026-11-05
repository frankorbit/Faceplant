import SwiftUI

/// 入口：录制新脸、附近通话、已有录制、留言列表、调试页。
struct HomeScreen: View {
    @State private var recordings: [FaceRecording] = []
    @State private var messages: [FaceMessage] = []
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
                    NavigationLink {
                        CallScreen()
                    } label: {
                        Label("附近通话", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                Section("我的脸") {
                    if recordings.isEmpty {
                        Text("还没有录制。录一段 5 到 15 秒的脸，说句话、做几个夸张表情。")
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

                Section("留言") {
                    if messages.isEmpty {
                        Text("在放置页把脸种到墙上后点「留言在这里」，下次回到那里就能看到。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        NavigationLink {
                            MessageRevisitScreen(message: message)
                        } label: {
                            MessageRow(message: message)
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
            messages = try FaceMessageStore().list()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

private struct Thumbnail: View {
    let path: String

    var body: some View {
        if let image = UIImage(contentsOfFile: path) {
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
    }
}

private struct RecordingRow: View {
    let recording: FaceRecording

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(path: recording.thumbnailURL.path)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.manifest.createdAt, format: .dateTime.month().day().hour().minute())
                Text(String(
                    format: "%.1f 秒 · %d 帧%@",
                    recording.manifest.duration,
                    recording.manifest.meshFrameCount,
                    recording.manifest.hasAudio ? " · 有声音" : ""
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MessageRow: View {
    let message: FaceMessage

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(path: message.thumbnailURL.path)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.manifest.title.isEmpty ? "未命名留言" : message.manifest.title)
                Text(message.manifest.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(locator)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var locator: String {
        var parts = [String]()
        if message.manifest.hasWorldMap { parts.append("世界地图") }
        if message.manifest.referenceImageUsable { parts.append("参考图") }
        return parts.isEmpty ? "没有定位数据" : "定位：" + parts.joined(separator: " + ")
    }
}
