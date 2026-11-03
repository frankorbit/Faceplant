import Foundation
import os

/// 录制包的存放目录：Application Support/Recordings。只做本地存储，不上传。
struct FaceRecordingStore {
    let directory: URL
    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "store")

    init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        directory = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makePackageURL() -> URL {
        directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(FaceRecording.packageExtension)
    }

    /// 按创建时间倒序。损坏的包跳过并记日志，不让一个坏包拖垮列表。
    func list() throws -> [FaceRecording] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == FaceRecording.packageExtension }
            .compactMap { url in
                do {
                    return try FaceRecording.load(url: url)
                } catch {
                    Self.logger.error("跳过损坏的录制包 \(url.lastPathComponent): \(String(describing: error))")
                    return nil
                }
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func delete(_ recording: FaceRecording) throws {
        try FileManager.default.removeItem(at: recording.url)
    }
}
