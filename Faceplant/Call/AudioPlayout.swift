import AVFoundation
import Foundation
import os

/// 播对端发来的 PCM：AVAudioEngine 上挂一个 AVAudioPlayerNode，包来了就排队。
///
/// 格式跟着第一个包走，中途变了就重连节点。没有抖动缓冲：局域网丢包只会出现一小段静音。
/// 线程：`enqueue` 任意线程，内部串行。
final class AudioPlayout {
    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "audioPlayout")
    private let queue = DispatchQueue(label: "com.frank.faceplant.audioPlayout")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    init() {
        engine.attach(player)
    }

    func enqueue(_ packet: AudioPacket) {
        queue.async { [weak self] in self?.schedule(packet) }
    }

    func stop() {
        queue.async { [self] in
            player.stop()
            engine.stop()
            format = nil
        }
    }

    private func schedule(_ packet: AudioPacket) {
        var streamDescription = packet.format
        guard let packetFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            Self.logger.warning("无法识别的音频格式")
            return
        }
        if format != packetFormat {
            do {
                try reconnect(format: packetFormat)
            } catch {
                Self.logger.error("音频引擎启动失败: \(String(describing: error))")
                return
            }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: packetFormat, frameCapacity: packet.frameCount) else { return }
        buffer.frameLength = packet.frameCount
        // 非交错格式每个声道一个 buffer，发送端的字节就是按这个顺序排的
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var offset = 0
        packet.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for audioBuffer in buffers {
                let count = Int(audioBuffer.mDataByteSize)
                guard offset + count <= bytes.count, let destination = audioBuffer.mData else { return }
                destination.copyMemory(from: base + offset, byteCount: count)
                offset += count
            }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            player.play()
        }
    }

    private func reconnect(format newFormat: AVAudioFormat) throws {
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        format = newFormat
    }
}
