import CoreMedia
import Foundation
import Metal
import os
import VideoToolbox

/// 把对端发来的 H.264 包解成 BGRA 像素缓冲并包成 Metal 纹理。
///
/// 收到带 SPS/PPS 的包时重建格式描述；中途加入或丢包后只从关键帧重新开始解。
/// 线程：`decode` 任意线程，内部串行；`onFrame` 在解码队列。
final class VideoDecoder {
    var onFrame: ((PixelBufferTextureCache.TextureRef) -> Void)?

    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "videoDecoder")
    private let queue = DispatchQueue(label: "com.frank.faceplant.videoDecoder")
    private let textureCache: PixelBufferTextureCache
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var awaitingKeyframe = true

    init(device: MTLDevice) throws {
        textureCache = try PixelBufferTextureCache(device: device)
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func decode(_ packet: VideoPacket) {
        queue.async { [weak self] in self?.process(packet) }
    }

    private func process(_ packet: VideoPacket) {
        do {
            if !packet.parameterSets.isEmpty {
                try updateFormat(parameterSets: packet.parameterSets)
            }
            guard let session, let formatDescription else { return }
            if awaitingKeyframe {
                guard packet.isKeyframe else { return }
                awaitingKeyframe = false
            }
            let sampleBuffer = try Self.makeSampleBuffer(packet, format: formatDescription)
            // 不带异步标志时输出回调在本队列同步执行
            let handler: VTDecompressionOutputHandler = { [weak self] status, _, imageBuffer, _, _ in
                guard let self, status == noErr, let imageBuffer else { return }
                deliver(imageBuffer)
            }
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil, outputHandler: handler
            )
            if status != noErr {
                awaitingKeyframe = true
                Self.logger.warning("解码失败 \(status)，等下一个关键帧")
            }
        } catch {
            awaitingKeyframe = true
            Self.logger.error("解码出错: \(String(describing: error))")
        }
    }

    private func deliver(_ imageBuffer: CVImageBuffer) {
        do {
            let texture = try textureCache.texture(for: imageBuffer, format: .bgra8Unorm)
            textureCache.flush()
            onFrame?(texture)
        } catch {
            Self.logger.error("解码帧转纹理失败: \(String(describing: error))")
        }
    }

    private func updateFormat(parameterSets: [Data]) throws {
        guard parameterSets.count >= 2 else { throw FaceplantError.videoCodecFailed("关键帧缺少 SPS/PPS") }
        let description = try Self.makeFormatDescription(sps: parameterSets[0], pps: parameterSets[1])
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            formatDescription = description
            return
        }
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw FaceplantError.videoCodecFailed("创建解码器失败 \(status)") }
        session = created
        formatDescription = description
        awaitingKeyframe = true
    }

    private static func makeFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes -> OSStatus in
            pps.withUnsafeBytes { ppsBytes -> OSStatus in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw FaceplantError.videoCodecFailed("SPS/PPS 无效 \(status)") }
        return description
    }

    private static func makeSampleBuffer(_ packet: VideoPacket, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: packet.data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: packet.data.count, flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw FaceplantError.videoCodecFailed("分配块缓冲失败 \(status)") }
        status = CMBlockBufferAssureBlockMemory(blockBuffer)
        guard status == noErr else { throw FaceplantError.videoCodecFailed("块缓冲内存分配失败 \(status)") }
        status = packet.data.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: packet.data.count
            )
        }
        guard status == noErr else { throw FaceplantError.videoCodecFailed("拷贝数据失败 \(status)") }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: packet.timestamp, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = packet.data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw FaceplantError.videoCodecFailed("创建样本失败 \(status)") }
        return sampleBuffer
    }
}
