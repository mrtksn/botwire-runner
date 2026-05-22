//
//  RuntimeBusContracts.swift
//  BotwireShared
//
//  Shared wire contracts for cross-peer runtime bus messages.
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum BotwireBusMessageKind: String, Codable, CaseIterable, Sendable {
    case algorithmRun
    case codeBlockExecute
    case httpRequest
    case timerTick
    case dbQuery
    case dbMutate
    case fileRead
    case fileWrite
    case stateChange
    case deploy
    case recall
    case observerEvent
    case pauseCheckpoint
    case pauseResume
}

public struct BotwireBusMessage: Codable, Sendable {
    public let id: String
    public let kind: String
    public let startupID: UUID
    public let payload: Data
    public let replyTo: String?
    public let originPeerID: String
    public var hopCount: Int
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        kind: String,
        startupID: UUID,
        payload: Data,
        replyTo: String? = nil,
        originPeerID: String,
        hopCount: Int = 0,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.startupID = startupID
        self.payload = payload
        self.replyTo = replyTo
        self.originPeerID = originPeerID
        self.hopCount = hopCount
        self.timestamp = timestamp
    }

    public init(
        kind: BotwireBusMessageKind,
        startupID: UUID,
        payload: Data,
        replyTo: String? = nil,
        originPeerID: String,
        hopCount: Int = 0,
        timestamp: Date = Date()
    ) {
        self.init(
            kind: kind.rawValue,
            startupID: startupID,
            payload: payload,
            replyTo: replyTo,
            originPeerID: originPeerID,
            hopCount: hopCount,
            timestamp: timestamp
        )
    }

    public func hopped() -> BotwireBusMessage {
        var copy = self
        copy.hopCount += 1
        return copy
    }

    public func decoded<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }

    public static func create<T: Encodable>(
        kind: BotwireBusMessageKind,
        startupID: UUID,
        payload: T,
        replyTo: String? = nil,
        originPeerID: String
    ) -> BotwireBusMessage? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return BotwireBusMessage(
            kind: kind,
            startupID: startupID,
            payload: data,
            replyTo: replyTo,
            originPeerID: originPeerID
        )
    }
}

public struct BotwireBusResponse: Codable, Sendable {
    public let messageID: String
    public let success: Bool
    public let payload: Data?
    public let error: String?

    public init(messageID: String, success: Bool, payload: Data? = nil, error: String? = nil) {
        self.messageID = messageID
        self.success = success
        self.payload = payload
        self.error = error
    }

    public static func ok(for message: BotwireBusMessage, payload: Data? = nil) -> BotwireBusResponse {
        BotwireBusResponse(messageID: message.id, success: true, payload: payload, error: nil)
    }

    public static func error(for message: BotwireBusMessage, _ error: String) -> BotwireBusResponse {
        BotwireBusResponse(messageID: message.id, success: false, payload: nil, error: error)
    }

    public func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = payload else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

public struct BotwireBusAlgorithmRunPayload: Codable, Sendable {
    public let algorithmID: UUID
    public let trigger: String
    public let inputJSON: String?
    public let preferredEngine: String?
    public let capabilities: BotwireBusCapabilities?

    public init(algorithmID: UUID, trigger: String, inputJSON: String? = nil, preferredEngine: String? = nil, capabilities: BotwireBusCapabilities? = nil) {
        self.algorithmID = algorithmID
        self.trigger = trigger
        self.inputJSON = inputJSON
        self.preferredEngine = preferredEngine
        self.capabilities = capabilities
    }
}

public struct BotwireBusTimerTickPayload: Codable, Sendable {
    public let algorithmID: UUID
    public let timerName: String?
    public let scheduledAt: Date
    public let intervalSeconds: Int
    public let tick: Int?

    public init(algorithmID: UUID, timerName: String? = nil, scheduledAt: Date, intervalSeconds: Int, tick: Int? = nil) {
        self.algorithmID = algorithmID
        self.timerName = timerName
        self.scheduledAt = scheduledAt
        self.intervalSeconds = intervalSeconds
        self.tick = tick
    }
}

public struct BotwireBusCapabilities: Codable, Sendable {
    public var networkEnabled: Bool
    public var fileSystemEnabled: Bool
    public var sqlEnabled: Bool
    public var llmConfigEnabled: Bool
    public var timeoutMs: Int

    public init(networkEnabled: Bool = true, fileSystemEnabled: Bool = false, sqlEnabled: Bool = false, llmConfigEnabled: Bool = false, timeoutMs: Int = 30_000) {
        self.networkEnabled = networkEnabled
        self.fileSystemEnabled = fileSystemEnabled
        self.sqlEnabled = sqlEnabled
        self.llmConfigEnabled = llmConfigEnabled
        self.timeoutMs = timeoutMs
    }
}

public struct BotwireBusStateChangePayload: Codable, Sendable {
    public let startupID: UUID
    public let isActive: Bool

    public init(startupID: UUID, isActive: Bool) {
        self.startupID = startupID
        self.isActive = isActive
    }
}

public struct BotwireBusHTTPRequestPayload: Codable, Sendable {
    public let routeHash: String
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: String
    public let query: [String: String]

    public init(routeHash: String, method: String, path: String, headers: [String: String] = [:], body: String = "", query: [String: String] = [:]) {
        self.routeHash = routeHash
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.query = query
    }
}

public struct BotwireBusObserverEventPayload: Codable, Sendable {
    public let eventKind: String
    public let algorithmID: String?
    public let algorithmName: String?
    public let detail: String
    public let metadata: [String: String]?

    public init(eventKind: String, algorithmID: String? = nil, algorithmName: String? = nil, detail: String, metadata: [String: String]? = nil) {
        self.eventKind = eventKind
        self.algorithmID = algorithmID
        self.algorithmName = algorithmName
        self.detail = detail
        self.metadata = metadata
    }
}

public struct BotwireBusDatabasePayload: Codable, Sendable {
    public let operation: String
    public let databaseID: UUID
    public let databaseName: String
    public let payloadJSON: String

    public init(operation: String, databaseID: UUID, databaseName: String, payloadJSON: String) {
        self.operation = operation
        self.databaseID = databaseID
        self.databaseName = databaseName
        self.payloadJSON = payloadJSON
    }
}

public struct BotwireBusDeployPayload: Codable, Sendable {
    public let transferPayloadJSON: String

    public init(transferPayloadJSON: String) {
        self.transferPayloadJSON = transferPayloadJSON
    }
}

public struct BotwireBusRecallPayload: Codable, Sendable {
    public let startupID: UUID

    public init(startupID: UUID) {
        self.startupID = startupID
    }
}

public struct BotwireBusFilePayload: Codable, Sendable {
    public let startupID: UUID
    public let fileID: String?
    public let operation: String
    public let name: String?
    public let data: String?
    public let mimeType: String?

    public init(startupID: UUID, fileID: String? = nil, operation: String, name: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.startupID = startupID
        self.fileID = fileID
        self.operation = operation
        self.name = name
        self.data = data
        self.mimeType = mimeType
    }
}

public struct BotwireBusPauseCheckpointPayload: Codable, Sendable {
    public let label: String
    public let algorithmID: UUID?
    public let algorithmName: String?
    public let codeblockID: String?
    public let codeblockName: String?

    public init(label: String, algorithmID: UUID? = nil, algorithmName: String? = nil, codeblockID: String? = nil, codeblockName: String? = nil) {
        self.label = label
        self.algorithmID = algorithmID
        self.algorithmName = algorithmName
        self.codeblockID = codeblockID
        self.codeblockName = codeblockName
    }
}

public struct BotwireBusPauseResumePayload: Codable, Sendable {
    public let action: String

    public init(action: String) {
        self.action = action
    }
}
