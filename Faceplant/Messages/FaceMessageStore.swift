import Foundation
import os

/// 留言包的存放目录：Application Support/Messages。只做本地存储，不上传。
struct FaceMessageStore {
    let directory: URL
    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "messageStore")

    init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        directory = base.appendingPathComponent("Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makePackageURL() -> URL {
        directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(FaceMessage.packageExtension)
    }

    /// 按创建时间倒序。损坏的包跳过并记日志。
    func list() throws -> [FaceMessage] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == FaceMessage.packageExtension }
            .compactMap { url in
                do {
                    return try FaceMessage.load(url: url)
                } catch {
                    Self.logger.error("跳过损坏的留言包 \(url.lastPathComponent): \(String(describing: error))")
                    return nil
                }
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func delete(_ message: FaceMessage) throws {
        try FileManager.default.removeItem(at: message.url)
    }
}
