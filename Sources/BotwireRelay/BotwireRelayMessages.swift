import Foundation

public enum BotwireRelayMessageType: String, Codable, Sendable {
    case auth
    case authOK = "auth_ok"
    case authError = "auth_error"
    case registerRoutes = "register_routes"
    case routesRegistered = "routes_registered"
    case httpForward = "http_forward"
    case httpResponse = "http_response"
    case ping
    case pong
    case runnerRegister = "runner.register"
    case runnerHeartbeat = "runner.heartbeat"
    case runStart = "run.start"
    case runEvent = "run.event"
    case runCancel = "run.cancel"
    case runPause = "run.pause"
    case runResume = "run.resume"
    case toolCall = "tool.call"
    case toolResult = "tool.result"
    case fileRead = "file.read"
    case fileWrite = "file.write"
    case dbCommand = "db.command"
    case error
}

public struct BotwireRelayEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public var type: BotwireRelayMessageType
    public var id: String
    public var payload: Payload

    public init(type: BotwireRelayMessageType, id: String = UUID().uuidString, payload: Payload) {
        self.type = type
        self.id = id
        self.payload = payload
    }
}

public struct RunnerHeartbeatPayload: Codable, Sendable {
    public var runnerID: String
    public var runnerName: String
    public var platform: String
    public var timestamp: Date

    public init(runnerID: String, runnerName: String, platform: String = "linux", timestamp: Date = Date()) {
        self.runnerID = runnerID
        self.runnerName = runnerName
        self.platform = platform
        self.timestamp = timestamp
    }
}
