import ARKit
import Foundation
import os
import simd
import UIKit

/// 把"当前放好的脸"固化成一条留言：抓世界地图、裁参考图、复制录制包、写 manifest。
///
/// `save` 可以在任意线程调用，重活在后台队列做，completion 在主线程回调。
/// 地图和参考图至少要成一个，否则重访时没法定位，直接报错。
enum FaceMessageCapture {
    struct Request {
        /// 保存那一刻的帧，裁参考图和估物理尺寸都用它
        let frame: ARFrame
        /// 脸的世界变换，和地图同一坐标系
        let faceTransform: simd_float4x4
        let recording: FaceRecording
        let title: String
    }

    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "messageCapture")
    private static let queue = DispatchQueue(label: "com.frank.faceplant.messageCapture", qos: .userInitiated)

    static func save(_ request: Request, session: ARSession, completion: @escaping (Result<FaceMessage, Error>) -> Void) {
        session.getCurrentWorldMap { worldMap, mapError in
            queue.async {
                let result = Result { try write(request, worldMap: worldMap, mapError: mapError) }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private static func write(_ request: Request, worldMap: ARWorldMap?, mapError: Error?) throws -> FaceMessage {
        if let mapError {
            logger.warning("拿不到世界地图，只靠参考图: \(mapError.localizedDescription)")
        }
        let reference = makeReference(request)
        guard worldMap != nil || reference?.usable == true else {
            throw FaceplantError.messageSaveFailed("世界地图没建好，参考图也不够清楚；环视一下周围、对着有纹理的墙再试")
        }

        let store = try FaceMessageStore()
        let packageURL = store.makePackageURL()
        let message = FaceMessage(url: packageURL, manifest: FaceMessageManifest(
            formatVersion: FaceMessageManifest.currentFormatVersion,
            createdAt: Date(),
            title: request.title,
            faceTransform: request.faceTransform.flattened,
            faceRelativeToImage: reference.map { (simd_inverse($0.output.imageTransform) * request.faceTransform).flattened },
            referenceImageWidth: reference?.output.physicalWidth,
            referenceImageUsable: reference?.usable ?? false,
            hasWorldMap: worldMap != nil,
            deviceModel: request.recording.manifest.deviceModel
        ))

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(at: request.recording.url, to: message.recordingURL)
            if let worldMap {
                let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                try data.write(to: message.worldMapURL, options: .atomic)
            }
            if let reference {
                try writeJPEG(reference.output.image, to: message.referenceImageURL, maxSide: nil)
                try writeJPEG(reference.output.image, to: message.thumbnailURL, maxSide: 256)
            }
            try message.manifest.write(to: message.manifestURL)
        } catch {
            // 半成品包会在列表里显示成损坏，直接清掉
            try? fileManager.removeItem(at: packageURL)
            throw error
        }
        logger.info("留言已保存 地图=\(worldMap != nil) 参考图可用=\(reference?.usable ?? false)")
        return message
    }

    private struct Reference {
        let output: ReferenceImageMaker.Output
        let usable: Bool
    }

    /// 做参考图并让 ARKit 校验。校验是异步的，这里在后台队列上等它，最多两秒。
    private static func makeReference(_ request: Request) -> Reference? {
        let output: ReferenceImageMaker.Output
        do {
            output = try ReferenceImageMaker.make(frame: request.frame, faceTransform: request.faceTransform)
        } catch {
            logger.warning("参考图生成失败: \(String(describing: error))")
            return nil
        }
        guard let cgImage = output.image.cgImage else { return nil }
        let image = ARReferenceImage(cgImage, orientation: .up, physicalWidth: CGFloat(output.physicalWidth))
        var usable = false
        let done = DispatchSemaphore(value: 0)
        image.validate { error in
            usable = error == nil
            if let error {
                logger.warning("参考图不可用: \(error.localizedDescription)")
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return Reference(output: output, usable: usable)
    }

    private static func writeJPEG(_ image: UIImage, to url: URL, maxSide: CGFloat?) throws {
        var target = image
        if let maxSide, max(image.size.width, image.size.height) > maxSide {
            let scale = maxSide / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            target = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        guard let data = target.jpegData(compressionQuality: 0.9) else {
            throw FaceplantError.messageSaveFailed("参考图编码失败")
        }
        try data.write(to: url, options: .atomic)
    }
}
