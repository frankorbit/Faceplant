import AVFoundation

/// 麦克风权限。ARKit 的 `providesAudioData` 要求先拿到授权，否则会话只给画面不给声音。
enum MicrophonePermission {
    /// completion 在主线程回调
    static func request(_ completion: @escaping (Bool) -> Void) {
        let deliver: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: deliver)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(deliver)
        }
    }
}
