import Foundation
import MultipeerConnectivity
import os
import UIKit

/// 附近两台设备之间的 MultipeerConnectivity 链路。
///
/// 双方都同时广播和搜索，省掉选人界面：发现对方后由 displayName 字典序小的一方发邀请，另一方自动接受。
/// 只保留第一个连上的对端，多出来的忽略。
///
/// 线程：`start` / `stop` 主线程；`send` 任意线程；`onMessage` 在 MC 的回调线程，`onStateChange` 回主线程。
final class NearbySession: NSObject {
    static let serviceType = "faceplant-call"

    enum State: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
    }

    var onStateChange: ((State) -> Void)?
    var onMessage: ((CallMessage) -> Void)?

    private static let logger = Logger(subsystem: "com.frank.faceplant", category: "nearby")
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let connectedPeer = OSAllocatedUnfairLock<MCPeerID?>(initialState: nil)
    private var sendFailures = 0

    var isConnected: Bool { connectedPeer.withLock { $0 != nil } }

    override init() {
        // iOS 16 起 UIDevice.name 只给型号，两台同款会重名；加随机后缀既区分设备，也用来决定谁发邀请
        let suffix = String(UInt16.random(in: 0 ... UInt16.max), radix: 16)
        peerID = MCPeerID(displayName: "\(UIDevice.current.name)-\(suffix)")
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    deinit {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        notify(.searching)
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedPeer.withLock { $0 = nil }
        notify(.idle)
    }

    /// 没连上时静默丢弃并返回 false；发送失败只记日志，链路断开会从 session 回调过来
    @discardableResult
    func send(_ message: CallMessage, mode: MCSessionSendDataMode) -> Bool {
        guard let peer = connectedPeer.withLock({ $0 }) else { return false }
        do {
            try session.send(message.encoded(), toPeers: [peer], with: mode)
            return true
        } catch {
            sendFailures += 1
            let failures = sendFailures
            if failures % 30 == 1 {
                Self.logger.warning("发送失败 \(failures) 次: \(error.localizedDescription)")
            }
            return false
        }
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

extension NearbySession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard !isConnected, peerID.displayName < peer.displayName else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
        notify(.connecting(peer.displayName))
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Self.logger.error("搜索失败: \(error.localizedDescription)")
    }
}

extension NearbySession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
        withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let accept = !isConnected
        invitationHandler(accept, accept ? session : nil)
        if accept {
            notify(.connecting(peer.displayName))
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Self.logger.error("广播失败: \(error.localizedDescription)")
    }
}

extension NearbySession: MCSessionDelegate {
    func session(_ session: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            connectedPeer.withLock { $0 = peer }
            // 连上就停广播和搜索，避免第三台设备插进来
            advertiser.stopAdvertisingPeer()
            browser.stopBrowsingForPeers()
            notify(.connected(peer.displayName))
        case .notConnected:
            let wasCurrent = connectedPeer.withLock { current -> Bool in
                guard current == peer else { return false }
                current = nil
                return true
            }
            if wasCurrent {
                advertiser.startAdvertisingPeer()
                browser.startBrowsingForPeers()
                notify(.searching)
            }
        case .connecting:
            notify(.connecting(peer.displayName))
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        do {
            try onMessage?(CallMessage(decoding: data))
        } catch {
            Self.logger.warning("丢弃损坏消息: \(String(describing: error))")
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peer: MCPeerID) {}

    func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peer: MCPeerID, with progress: Progress
    ) {}

    func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peer: MCPeerID,
        at localURL: URL?, withError error: Error?
    ) {}
}
