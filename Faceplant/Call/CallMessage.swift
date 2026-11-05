import AVFoundation
import Foundation

/// 一段压缩后的贴图视频帧。关键帧带 SPS/PPS，数据是 AVCC 布局（4 字节大端长度前缀的 NAL）。
struct VideoPacket {
    var isKeyframe: Bool
    var timestamp: TimeInterval
    var parameterSets: [Data]
    var data: Data
}

/// 一段原始 PCM。格式原样带过去，接收端按它建 AVAudioFormat，不猜采样率和声道。
struct AudioPacket {
    var format: AudioStreamBasicDescription
    var frameCount: UInt32
    var timestamp: TimeInterval
    var data: Data

    /// 从 ARKit 给的麦克风样本直接取字节；数据没就位或拿不到格式返回 nil
    init?(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { return nil }
        format = streamDescription.pointee
        frameCount = UInt32(CMSampleBufferGetNumSamples(sampleBuffer))
        timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        data = bytes
    }

    init(format: AudioStreamBasicDescription, frameCount: UInt32, timestamp: TimeInterval, data: Data) {
        self.format = format
        self.frameCount = frameCount
        self.timestamp = timestamp
        self.data = data
    }
}

/// 附近通话链路上的消息。第一个字节是类型，其余是各自的二进制负载。
///
/// 顶点帧和音频走不可靠信道（丢了就丢，最新的才有用），拓扑、问候、视频走可靠信道。
enum CallMessage {
    case hello(deviceName: String, textureSize: Int)
    /// 对方的 ARKit 原始拓扑（未加盖），连接后发一次
    case topology(FaceMeshTopology)
    /// 对方的原始顶点帧（未加盖），接收端自己加盖
    case meshFrame(FaceMeshFrame)
    case video(VideoPacket)
    case audio(AudioPacket)

    static let meshFlags: MeshStreamFormat.Flags = [.halfFloatVertices, .blendShapes, .eyeTransforms]

    private enum Tag: UInt8 {
        case hello = 1
        case topology = 2
        case meshFrame = 3
        case video = 4
        case audio = 5
    }

    func encoded() throws -> Data {
        var data = Data()
        switch self {
        case let .hello(deviceName, textureSize):
            data.appendValue(Tag.hello.rawValue)
            data.appendString(deviceName)
            data.appendValue(UInt32(textureSize))
        case let .topology(topology):
            data.appendValue(Tag.topology.rawValue)
            data.append(topology.serialized())
        case let .meshFrame(frame):
            data.appendValue(Tag.meshFrame.rawValue)
            data.appendValue(UInt32(frame.vertices.count))
            try data.append(MeshFrameCodec.encode(frame, vertexCount: frame.vertices.count, flags: Self.meshFlags))
        case let .video(packet):
            data.appendValue(Tag.video.rawValue)
            data.appendValue(packet.isKeyframe ? UInt8(1) : UInt8(0))
            data.appendValue(packet.timestamp)
            data.appendValue(UInt32(packet.parameterSets.count))
            for set in packet.parameterSets {
                data.appendLengthPrefixed(set)
            }
            data.appendLengthPrefixed(packet.data)
        case let .audio(packet):
            data.appendValue(Tag.audio.rawValue)
            data.appendValue(packet.format)
            data.appendValue(packet.frameCount)
            data.appendValue(packet.timestamp)
            data.appendLengthPrefixed(packet.data)
        }
        return data
    }

    init(decoding data: Data) throws {
        var reader = BinaryReader(data)
        let rawTag: UInt8 = try reader.read()
        guard let tag = Tag(rawValue: rawTag) else { throw FaceplantError.callMessageCorrupted("未知消息类型 \(rawTag)") }
        switch tag {
        case .hello:
            let name = try reader.readString()
            let textureSize: UInt32 = try reader.read()
            self = .hello(deviceName: name, textureSize: Int(textureSize))
        case .topology:
            self = try .topology(FaceMeshTopology(serialized: reader.readData(count: reader.remaining)))
        case .meshFrame:
            let vertexCount = try Int(reader.read() as UInt32)
            guard vertexCount > 0, vertexCount < 10000 else { throw FaceplantError.callMessageCorrupted("顶点数不合理 \(vertexCount)") }
            let frameSize = MeshStreamFormat.frameByteCount(vertexCount: vertexCount, flags: Self.meshFlags)
            let start = try reader.skip(frameSize)
            self = try .meshFrame(MeshFrameCodec.decode(data, at: start, vertexCount: vertexCount, flags: Self.meshFlags))
        case .video:
            let keyframe: UInt8 = try reader.read()
            let timestamp: TimeInterval = try reader.read()
            let setCount: UInt32 = try reader.read()
            guard setCount <= 8 else { throw FaceplantError.callMessageCorrupted("参数集数量不合理 \(setCount)") }
            var sets = [Data]()
            for _ in 0 ..< setCount {
                try sets.append(reader.readLengthPrefixedData())
            }
            let payload = try reader.readLengthPrefixedData()
            self = .video(VideoPacket(isKeyframe: keyframe != 0, timestamp: timestamp, parameterSets: sets, data: payload))
        case .audio:
            let format: AudioStreamBasicDescription = try reader.read()
            let frameCount: UInt32 = try reader.read()
            let timestamp: TimeInterval = try reader.read()
            let payload = try reader.readLengthPrefixedData()
            self = .audio(AudioPacket(format: format, frameCount: frameCount, timestamp: timestamp, data: payload))
        }
    }
}
