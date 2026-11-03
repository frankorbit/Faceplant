import AVFoundation
import Foundation

/// 探针：在 ARKit 已经占用前后摄像头的情况下，尝试再开一路前置 AVCaptureSession。
///
/// 目的只是回答"能不能拿到前置画面"，所以只统计帧数和记录中断原因，不处理画面。
final class FrontCameraProbe: NSObject {
    enum State: CustomStringConvertible {
        case idle
        case starting
        case running(frames: Int)
        case interrupted(reason: String)
        case failed(String)

        var description: String {
            switch self {
            case .idle: "idle"
            case .starting: "starting"
            case let .running(frames): "running · frames \(frames)"
            case let .interrupted(reason): "interrupted · \(reason)"
            case let .failed(message): "failed · \(message)"
            }
        }
    }

    var onStateChange: ((State) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.frank.faceplant.frontCameraProbe")
    private let output = AVCaptureVideoDataOutput()
    private var frameCount = 0
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observeSessionNotifications()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        update(.starting)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try configureSession()
                session.startRunning()
                // startRunning 本身不抛错，真实状态靠通知和帧回调反馈
                if !session.isRunning {
                    update(.failed("startRunning 返回后 isRunning 仍为 false"))
                }
            } catch {
                update(.failed("\(error)"))
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.stopRunning()
            update(.idle)
        }
    }

    private func configureSession() throws {
        guard session.inputs.isEmpty else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw FaceplantError.frontCameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw FaceplantError.frontCameraUnavailable
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = rawReason.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.update(.interrupted(reason: reason.map(Self.describe) ?? "unknown(\(rawReason ?? -1))"))
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.update(.failed(error?.localizedDescription ?? "runtime error"))
        })
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: "videoDeviceNotAvailableInBackground"
        case .audioDeviceInUseByAnotherClient: "audioDeviceInUseByAnotherClient"
        case .videoDeviceInUseByAnotherClient: "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "videoDeviceNotAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure: "videoDeviceNotAvailableDueToSystemPressure"
        case .sensitiveContentMitigationActivated: "sensitiveContentMitigationActivated"
        @unknown default: "unknown(\(reason.rawValue))"
        }
    }

    private func update(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

extension FrontCameraProbe: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        if frameCount % 30 == 1 {
            update(.running(frames: frameCount))
        }
    }
}
