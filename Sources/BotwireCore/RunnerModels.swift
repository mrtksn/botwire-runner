import Foundation

public struct BotwireRunnerConfig: Codable, Sendable {
    public var relayBaseURL: URL
    public var tunnelURL: URL
    public var runnerID: String
    public var runnerName: String
    public var workspacePath: String?
    public var relayAuthToken: String?
    public var sessionToken: String?
    public var shareableID: String?

    public init(
        relayBaseURL: URL = URL(string: "https://algo.botwire.app")!,
        tunnelURL: URL = URL(string: "wss://algo.botwire.app/tunnel")!,
        runnerID: String = UUID().uuidString,
        runnerName: String = ProcessInfo.processInfo.environment["HOSTNAME"] ?? "Botwire Linux Runner",
        workspacePath: String? = nil,
        relayAuthToken: String? = nil,
        sessionToken: String? = nil,
        shareableID: String? = nil
    ) {
        self.relayBaseURL = relayBaseURL
        self.tunnelURL = tunnelURL
        self.runnerID = runnerID
        self.runnerName = runnerName
        self.workspacePath = workspacePath
        self.relayAuthToken = relayAuthToken
        self.sessionToken = sessionToken
        self.shareableID = shareableID
    }
}

public struct BotwireRunRequest: Codable, Sendable {
    public var runID: String
    public var objective: String
    public var inputJSON: String?
    public var project: BotwireProjectBundle
    public var workspacePath: String?

    public init(
        runID: String = UUID().uuidString,
        objective: String,
        inputJSON: String? = nil,
        project: BotwireProjectBundle,
        workspacePath: String? = nil
    ) {
        self.runID = runID
        self.objective = objective
        self.inputJSON = inputJSON
        self.project = project
        self.workspacePath = workspacePath
    }
}

public struct BotwireRunEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case started
        case status
        case log
        case completed
        case failed
    }

    public var id: String
    public var runID: String
    public var kind: Kind
    public var message: String
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        runID: String,
        kind: Kind,
        message: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
    }
}

public struct RelayStatus: Codable, Sendable {
    public var version: String?
    public var connectedDevices: Int?
    public var pendingRequests: Int?
    public var raw: [String: JSONValue]

    public init(
        version: String? = nil,
        connectedDevices: Int? = nil,
        pendingRequests: Int? = nil,
        raw: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.connectedDevices = connectedDevices
        self.pendingRequests = pendingRequests
        self.raw = raw
    }
}
