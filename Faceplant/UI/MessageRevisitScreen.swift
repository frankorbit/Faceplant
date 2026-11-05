import SwiftUI

/// 重访留言页的 SwiftUI 壳，工具栏里可以删掉这条留言。
struct MessageRevisitScreen: View {
    let message: FaceMessage

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        MessageRevisitView(message: message)
            .ignoresSafeArea()
            .navigationTitle(message.manifest.title.isEmpty ? "留言" : message.manifest.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
            }
            .confirmationDialog("删除这条留言？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive, action: deleteMessage)
            }
            .alert("出错了", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func deleteMessage() {
        do {
            try FaceMessageStore().delete(message)
            dismiss()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

private struct MessageRevisitView: UIViewControllerRepresentable {
    let message: FaceMessage

    func makeUIViewController(context: Context) -> MessageRevisitViewController {
        MessageRevisitViewController(message: message)
    }

    func updateUIViewController(_ uiViewController: MessageRevisitViewController, context: Context) {}
}
