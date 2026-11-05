import AVFoundation
import CoreImage
import Foundation
import Metal
import os

/// 把烘焙贴图、网格帧与麦克风声音写成一个 `.faceplant` 包。
///
/// 线程约束：
/// - `capture` / `appendAudio` 在 ARSession delegate 队列调用，顶点流在该队列同步写入。
/// - 视频帧在 GPU 完成回调里、音频在收到后都转到 `writerQueue` 追加，每个 input 只从一个线程喂数据。
/// - `finish` 在 delegate 队列调用，等所有在途视频帧落盘后再收尾。
///
/// 时间轴：mesh 帧、视频帧、音频样本都用 `ARFrame.timestamp` 的时钟减去第一帧的时间；
/// ARKit 的音频样本和相机帧来自同一个 capture session，直接相减即可。
final class FaceRecorder {
    static let maxDuration: TimeInterval = 15
    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "recorder")

    let packageURL: URL

    private let topology: FaceMeshTopology
    private let textureSize: Int
    private let textureCache: PixelBufferTextureCache
    private let meshWriter: MeshStreamWriter
    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// 不录音时为 nil
    private let audioInput: AVAssetWriterInput?

    private let writerQueue = DispatchQueue(label: "com.frank.faceplant.recorder.writer")
    private let pendingAppends = DispatchGroup()

    // 以下状态只在 delegate 队列访问
    private var startTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var isAccepting = true
    private var droppedVideoFrames = 0

    // 以下只在 writerQueue 访问
    private var lastPixelBuffer: CVPixelBuffer?
    private var appendedAudioSamples = 0

    /// 已录制时长，秒
    var elapsed: TimeInterval {
        guard let startTimestamp, let lastTimestamp else { return 0 }
        return lastTimestamp - startTimestamp
    }

    init(
        packageURL: URL, topology: FaceMeshTopology, textureSize: Int, textureCache: PixelBufferTextureCache, includesAudio: Bool
    ) throws {
        self.packageURL = packageURL
        self.topology = topology
        self.textureSize = textureSize
        self.textureCache = textureCache

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try topology.write(to: packageURL.appendingPathComponent(FaceRecording.topologyFileName))
        meshWriter = try MeshStreamWriter(
            url: packageURL.appendingPathComponent(FaceRecording.meshFileName),
            vertexCount: topology.vertexCount,
            includesBlendShapes: true,
            includesEyeTransforms: true
        )

        let textureURL = packageURL.appendingPathComponent(FaceRecording.textureFileName)
        assetWriter = try AVAssetWriter(outputURL: textureURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: textureSize,
            AVVideoHeightKey: textureSize,
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: textureSize,
                kCVPixelBufferHeightKey as String: textureSize,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        guard assetWriter.canAdd(videoInput) else {
            throw FaceplantError.recordingSetupFailed("AVAssetWriter 不接受视频输入")
        }
        assetWriter.add(videoInput)

        audioInput = includesAudio ? try Self.addAudioInput(to: assetWriter) : nil
        guard assetWriter.startWriting() else {
            throw FaceplantError.recordingSetupFailed(assetWriter.error?.localizedDescription ?? "startWriting 失败")
        }
        assetWriter.startSession(atSourceTime: .zero)
    }

    /// AAC 单声道 64 kbps；输入是 ARKit 给的 PCM，采样率不同由 writer 转换
    private static func addAudioInput(to writer: AVAssetWriter) throws -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw FaceplantError.recordingSetupFailed("AVAssetWriter 不接受音频输入")
        }
        writer.add(input)
        return input
    }

    /// 在烘焙 pass 的 beforeCommit 钩子里调用：写顶点帧，并把烘焙结果 blit 进视频像素缓冲。
    func capture(frame: FaceMeshFrame, baked: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard isAccepting else { return }
        let start = startTimestamp ?? frame.timestamp
        startTimestamp = start
        lastTimestamp = frame.timestamp
        let relative = frame.timestamp - start

        var relativeFrame = frame
        relativeFrame.timestamp = relative
        try meshWriter.append(relativeFrame)

        // 视频帧允许丢，顶点帧不允许；两者各带时间戳，不要求一一对应
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            droppedVideoFrames += 1
            return
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            droppedVideoFrames += 1
            return
        }
        let target = try textureCache.texture(for: pixelBuffer, format: .bgra8Unorm)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            droppedVideoFrames += 1
            return
        }
        blit.label = "BakedToVideoFrame"
        blit.copy(from: baked, to: target.texture)
        blit.endEncoding()

        let presentationTime = CMTime(seconds: relative, preferredTimescale: 600)
        pendingAppends.enter()
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            writerQueue.async {
                defer { self.pendingAppends.leave() }
                _ = target // 保持 IOSurface 到 blit 完成
                let appended = self.videoInput.isReadyForMoreMediaData
                    && self.adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                if appended {
                    self.lastPixelBuffer = pixelBuffer
                } else {
                    Self.logger.warning("视频帧追加失败 t=\(relative, format: .fixed(precision: 3))")
                }
            }
        }
    }

    /// 把一段麦克风样本写进音轨，时间戳换成相对录制起点。第一帧视频之前到的声音丢掉，保证两条轨同一个零点。
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isAccepting, let audioInput, let start = startTimestamp else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let offset = CMTime(seconds: start, preferredTimescale: presentation.timescale)
        let relative = CMTimeSubtract(presentation, offset)
        guard relative >= .zero else { return }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: relative, decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed
        )
        guard status == noErr, let retimed else {
            Self.logger.warning("音频重定时失败 \(status)")
            return
        }
        writerQueue.async { [self] in
            if audioInput.isReadyForMoreMediaData, audioInput.append(retimed) {
                appendedAudioSamples += 1
            }
        }
    }

    /// 停止接收，等在途帧落盘，写缩略图与 manifest。completion 在任意队列回调。
    func finish(completion: @escaping (Result<FaceRecording, Error>) -> Void) {
        isAccepting = false
        let duration = elapsed
        let meshFrameCount = Int(meshWriter.frameCount)
        let dropped = droppedVideoFrames
        do {
            try meshWriter.finish()
        } catch {
            completion(.failure(error))
            return
        }

        pendingAppends.notify(queue: writerQueue) { [self] in
            let thumbnailSource = lastPixelBuffer
            let hasAudio = appendedAudioSamples > 0
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            assetWriter.finishWriting { [self] in
                if let error = assetWriter.error {
                    completion(.failure(error))
                    return
                }
                do {
                    if let thumbnailSource {
                        try Self.writeThumbnail(
                            from: thumbnailSource,
                            to: packageURL.appendingPathComponent(FaceRecording.thumbnailFileName)
                        )
                    }
                    let manifest = FaceRecordingManifest(
                        formatVersion: FaceRecordingManifest.currentFormatVersion,
                        createdAt: Date(),
                        duration: duration,
                        vertexCount: topology.vertexCount,
                        meshFrameCount: meshFrameCount,
                        textureSize: textureSize,
                        hasBlendShapes: true,
                        deviceModel: Self.deviceModel(),
                        hasAudio: hasAudio
                    )
                    try manifest.write(to: packageURL.appendingPathComponent(FaceRecording.manifestFileName))
                    Self.logger.info("录制完成 \(meshFrameCount) 帧，丢弃视频帧 \(dropped)")
                    completion(.success(FaceRecording(url: packageURL, manifest: manifest)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// 放弃本次录制，删除已写入的包。
    func discard() {
        isAccepting = false
        try? meshWriter.finish()
        pendingAppends.notify(queue: writerQueue) { [self] in
            assetWriter.cancelWriting()
            try? FileManager.default.removeItem(at: packageURL)
        }
    }

    private static func writeThumbnail(from pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let scale: CGFloat = 256 / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = CIContext().jpegRepresentation(of: image, colorSpace: colorSpace, options: [:])
        else {
            throw FaceplantError.thumbnailFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}
