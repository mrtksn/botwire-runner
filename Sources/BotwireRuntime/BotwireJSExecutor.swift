import BotwireCore
import Foundation

public struct BotwireJSExecutionRequest: Sendable {
    public var source: String
    public var objective: String
    public var inputJSON: String?
    public var projectId: String?
    public var algorithmId: String?
    public var codeBlockId: String?
    public var workspacePath: String?
    public var timeout: TimeInterval
    public var databaseMutationHandler: (@Sendable (BotwireDatabaseMutationEvent) -> Void)?

    public init(
        source: String,
        objective: String,
        inputJSON: String? = nil,
        projectId: String? = nil,
        algorithmId: String? = nil,
        codeBlockId: String? = nil,
        workspacePath: String? = nil,
        timeout: TimeInterval = 30,
        databaseMutationHandler: (@Sendable (BotwireDatabaseMutationEvent) -> Void)? = nil
    ) {
        self.source = source
        self.objective = objective
        self.inputJSON = inputJSON
        self.projectId = projectId
        self.algorithmId = algorithmId
        self.codeBlockId = codeBlockId
        self.workspacePath = workspacePath
        self.timeout = timeout
        self.databaseMutationHandler = databaseMutationHandler
    }
}

public struct BotwireDatabaseMutationEvent: Sendable {
    public let projectID: String
    public let databaseID: String?
    public let databaseName: String?
    public let collection: String
    public let operation: String
    public let rawOperation: String
    public let documentIDs: [String]
    public let touchedPropertyPaths: [String]
    public let sourceAlgorithmID: String?
    public let sourceCodeBlockID: String?
    public let timestamp: Date

    public init(
        projectID: String,
        databaseID: String? = nil,
        databaseName: String? = nil,
        collection: String,
        operation: String,
        rawOperation: String,
        documentIDs: [String] = [],
        touchedPropertyPaths: [String] = [],
        sourceAlgorithmID: String? = nil,
        sourceCodeBlockID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.projectID = projectID
        self.databaseID = databaseID
        self.databaseName = databaseName
        self.collection = collection
        self.operation = operation
        self.rawOperation = rawOperation
        self.documentIDs = documentIDs
        self.touchedPropertyPaths = touchedPropertyPaths
        self.sourceAlgorithmID = sourceAlgorithmID
        self.sourceCodeBlockID = sourceCodeBlockID
        self.timestamp = timestamp
    }
}

public struct BotwireJSExecutionReport: Codable, Sendable {
    public var success: Bool
    public var result: JSONValue?
    public var httpResponseJSON: JSONValue?
    public var logs: [String]
    public var events: [BotwireRunEvent]
    public var errorMessage: String?
    public var durationMs: Int

    public init(
        success: Bool,
        result: JSONValue? = nil,
        httpResponseJSON: JSONValue? = nil,
        logs: [String] = [],
        events: [BotwireRunEvent] = [],
        errorMessage: String? = nil,
        durationMs: Int = 0
    ) {
        self.success = success
        self.result = result
        self.httpResponseJSON = httpResponseJSON
        self.logs = logs
        self.events = events
        self.errorMessage = errorMessage
        self.durationMs = durationMs
    }
}

public protocol BotwireJSExecutor: Sendable {
    func execute(_ request: BotwireJSExecutionRequest, runID: String) async -> BotwireJSExecutionReport
    func cancel()
}

public enum BotwireJSExecutorFactory {
    public static func makeDefault() -> BotwireJSExecutor {
        #if os(Linux) && canImport(CJavaScriptCoreGTK)
        return LinuxJavaScriptCoreGTKExecutor()
        #elseif canImport(JavaScriptCore)
        return AppleJavaScriptCoreExecutor()
        #else
        return UnavailableJavaScriptCoreExecutor()
        #endif
    }
}
