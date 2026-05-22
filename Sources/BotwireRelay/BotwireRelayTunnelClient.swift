import BotwireCore
import Foundation
import NIOCore
import NIOPosix
import WebSocketKit

public enum BotwireRelayTunnelError: LocalizedError {
    case missingCredentials
    case invalidTunnelURL
    case closed

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Runner config is missing relayAuthToken or sessionToken. Run register first."
        case .invalidTunnelURL:
            return "Runner config has an invalid tunnel URL."
        case .closed:
            return "Relay tunnel closed."
        }
    }
}

public final class BotwireRelayTunnelClient: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var socket: WebSocket?
    public private(set) var config: BotwireRunnerConfig?

    /// Pending BREP forward responses, keyed by requestID.
    private let pendingLock = NSLock()
    private var pendingResponses: [String: PendingBREPResponse] = [:]

    private struct PendingBREPResponse {
        let semaphore: DispatchSemaphore
        var responseBody: String?
        var status: Int?
    }

    public init() {}

    deinit {
        try? group.syncShutdownGracefully()
    }

    public func connect(
        config: BotwireRunnerConfig,
        onMessage: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        self.config = config
        guard let relayAuthToken = config.relayAuthToken,
              let sessionToken = config.sessionToken else {
            throw BotwireRelayTunnelError.missingCredentials
        }

        var wsConfig = WebSocketClient.Configuration()
        wsConfig.maxFrameSize = 1024 * 1024 * 50 // 50MB

        let socketPromise = group.any().makePromise(of: WebSocket.self)
        try await WebSocket.connect(to: config.tunnelURL.absoluteString, configuration: wsConfig, on: group) { socket in
            socket.onText { [weak self] _, text in
                // Check if this is a brep_response for a pending forward
                self?.handlePossibleBREPResponse(text)
                onMessage(text)
            }
            socket.onBinary { [weak self] _, buffer in
                if let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                    self?.handlePossibleBREPResponse(text)
                    onMessage(text)
                }
            }
            socketPromise.succeed(socket)
        }.get()
        let socket = try await socketPromise.futureResult.get()
        self.socket = socket

        let auth: [String: String] = [
            "type": "auth",
            "peerID": config.runnerID,
            "token": relayAuthToken,
            "sessionToken": sessionToken
        ]
        try await sendJSON(auth)
    }

    public func disconnect() async {
        try? await socket?.close()
        socket = nil
    }

    public func sendPing() async throws {
        try await sendJSON(["type": "ping"])
    }

    public func registerRoutes(_ routes: [[String: String]]) async throws {
        try await sendJSON(["type": "register_routes", "routes": routes])
    }

    public func sendHTTPResponse(
        requestID: String,
        status: Int,
        headers: [String: String] = ["content-type": "application/json"],
        body: String
    ) async throws {
        try await sendJSON([
            "type": "http_response",
            "requestID": requestID,
            "status": status,
            "headers": headers,
            "body": body
        ])
    }

    public func sendBREPResponse(
        requestID: String,
        status: Int,
        headers: [String: String] = ["content-type": "application/json"],
        body: String
    ) async throws {
        try await sendJSON([
            "type": "brep_response",
            "requestID": requestID,
            "status": status,
            "headers": headers,
            "body": body
        ])
    }

    // MARK: - BREP Forward (send request to another peer via relay)

    /// Send a BREP request to another peer through the relay and wait for the response.
    /// This blocks the calling thread (using a semaphore) — suitable for use from
    /// synchronous bridge code. Returns the response body string, or nil on timeout/error.
    public func forwardBREPSync(
        targetPeerID: String,
        method: String,
        path: String,
        body: String,
        timeoutSeconds: Double = 30
    ) -> String? {
        let requestID = UUID().uuidString
        let semaphore = DispatchSemaphore(value: 0)

        pendingLock.lock()
        pendingResponses[requestID] = PendingBREPResponse(semaphore: semaphore)
        pendingLock.unlock()

        let msg: [String: Any] = [
            "type": "brep_forward",
            "targetPeerID": targetPeerID,
            "requestID": requestID,
            "method": method,
            "path": path,
            "headers": ["content-type": "application/json"],
            "body": body
        ]

        // Send asynchronously, then wait synchronously
        let sendGroup = DispatchGroup()
        sendGroup.enter()
        Task {
            do {
                try await self.sendJSON(msg)
            } catch {
                print("🔀 [BREP Forward] Send failed: \(error.localizedDescription)")
                self.pendingLock.lock()
                self.pendingResponses.removeValue(forKey: requestID)
                self.pendingLock.unlock()
                semaphore.signal()
            }
            sendGroup.leave()
        }

        let result = semaphore.wait(timeout: .now() + timeoutSeconds)

        pendingLock.lock()
        let response = pendingResponses.removeValue(forKey: requestID)
        pendingLock.unlock()

        if result == .timedOut {
            print("🔀 [BREP Forward] Timeout waiting for response requestID=\(requestID)")
            return nil
        }

        return response?.responseBody
    }

    /// Check if an incoming WebSocket message is a brep_response for a pending forward.
    private func handlePossibleBREPResponse(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "brep_response",
              let requestID = obj["requestID"] as? String else {
            return
        }

        pendingLock.lock()
        guard var pending = pendingResponses[requestID] else {
            pendingLock.unlock()
            return
        }
        pending.responseBody = obj["body"] as? String
        pending.status = obj["status"] as? Int
        pendingResponses[requestID] = pending
        let sem = pending.semaphore
        pendingLock.unlock()

        sem.signal()
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw BotwireRelayTunnelError.closed }
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await socket.send(text)
    }
}
