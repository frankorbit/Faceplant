import CoreMedia
import Foundation
import os
import VideoToolbox

/// 把烘焙贴图实时压成 H.264，供附近通话发送。
///
/// 低延迟配置：实时模式、Baseline、不允许帧重排、2 秒一个关键帧。关键帧带上 SPS/PPS，
/// 接收端随时加入都能从下一个关键帧开始解。
/// 线程：`encode` 任意线程，内部串行；`onPacket` 在 VideoToolbox 的回调线程。
final class VideoEncoder {
    var onPacket: ((VideoPacket) -> Void)?

    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "videoEncoder")
    private let queue = DispatchQueue(label: "com.frank.faceplant.videoEncoder")
    private var session: VTCompressionSession?

    init(width: Int, height: Int, bitrate: Int, frameRate: Int) throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw FaceplantError.videoCodecFailed("创建编码器失败 \(status)")
        }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: frameRate * 2)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2)),
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(created, key: key, value: value)
            if result != noErr {
                Self.logger.warning("编码属性 \(key) 设置失败 \(result)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
    }

    deinit {
        invalidate()
    }

    /// - Parameter forceKeyframe: 新对端刚连上时用，不用等下一个周期关键帧就能开始解
    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, forceKeyframe: Bool = false) {
        queue.async { [weak self] in
            guard let self, let session else { return }
            let presentation = CMTime(seconds: timestamp, preferredTimescale: 1_000_000)
            let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer, presentationTimeStamp: presentation, duration: .invalid,
                frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil
            )
            if status != noErr {
                Self.logger.warning("编码失败 \(status)")
            }
        }
    }

    /// 和 `encode` 同一队列串行，不会在编码中途销毁会话
    func invalidate() {
        queue.sync {
            guard let session else { return }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon, status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue().handle(sampleBuffer)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        var parameterSets = [Data]()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(of: format)
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onPacket?(VideoPacket(isKeyframe: isKeyframe, timestamp: timestamp, parameterSets: parameterSets, data: data))
    }

    /// 附件里没有 NotSync 就是关键帧
    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        return !CFDictionaryContainsKey(dictionary, key)
    }

    private static func parameterSets(of format: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        return (0 ..< count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}
