import AVFoundation

/// 各页面需要的音频会话配置。录制和通话都要放外放，否则 playAndRecord 默认走听筒。
enum AudioSessionConfigurator {
    enum Role {
        /// 录制页：采集麦克风，不放声音
        case recording
        /// Review、放置、重访：只放录好的声音
        case playback
        /// 附近通话：同时采集与播放，开系统的语音处理
        case call
    }

    static func activate(_ role: Role) throws {
        let session = AVAudioSession.sharedInstance()
        switch role {
        case .recording:
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        case .playback:
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
        case .call:
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        }
        try session.setActive(true, options: [])
    }
}
