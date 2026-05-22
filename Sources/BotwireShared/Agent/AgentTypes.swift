// AgentTypes.swift
// BotwireShared
//
// Platform-agnostic agent primitives shared across iOS, macOS, Android, and Linux.
// No UIKit, SwiftUI, or JavaScriptCore dependencies.

import Foundation

// MARK: - LLM API Profile

public struct SharedLLMProfile: Codable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public let proxyPath: String?

    public init(id: String, name: String, baseURL: String, apiKey: String, model: String, proxyPath: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.proxyPath = proxyPath
    }

    /// Resolved chat/completions endpoint URL.
    public var completionsURL: String {
        Self.resolveCompletionsURL(baseURL: baseURL, proxyPath: proxyPath)
    }

    public static func resolveCompletionsURL(baseURL: String, proxyPath: String?) -> String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let proxy = proxyPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if url.hasSuffix("/chat/completions") {
            return url
        }

        if let proxy, !proxy.isEmpty {
            if url.hasSuffix("/\(proxy)/v1") || url.hasSuffix("/\(proxy)") || url.hasSuffix("/v1") {
                return appendCompletionsEndpoint(to: url)
            }
            url += "/\(proxy)"
        }

        return appendCompletionsEndpoint(to: url)
    }

    private static func appendCompletionsEndpoint(to url: String) -> String {
        if url.hasSuffix("/chat/completions") {
            return url
        }
        if url.hasSuffix("/v1") {
            return url + "/chat/completions"
        }
        return url + "/v1/chat/completions"
    }
}

// MARK: - Agent Config

public struct SharedAgentConfig: Codable, Sendable {
    public let id: String
    public let name: String
    public let systemPrompt: String
    public let profileID: String
    public let maxTurns: Int
    public let maxToolCalls: Int
    public let maxInputTokens: Int
    public let maxOutputTokens: Int
    public let contexts: [String]

    public init(
        id: String,
        name: String,
        systemPrompt: String,
        profileID: String,
        maxTurns: Int = 12,
        maxToolCalls: Int = 40,
        maxInputTokens: Int = 500_000,
        maxOutputTokens: Int = 100_000,
        contexts: [String] = []
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.profileID = profileID
        self.maxTurns = maxTurns
        self.maxToolCalls = maxToolCalls
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.contexts = contexts
    }
}

// MARK: - Tool Definition

public struct SharedToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    /// JSON Schema string (object schema for parameters)
    public let parametersJSON: String
    public let isTerminal: Bool

    public init(name: String, description: String, parametersJSON: String, isTerminal: Bool = false) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.isTerminal = isTerminal
    }

    /// The parameters parsed as a JSON-serializable object.
    public var parametersObject: Any {
        guard let data = parametersJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return obj
    }
}

// MARK: - OpenAI-compatible message types

public struct SharedChatMessage: Codable, Sendable {
    public let role: String
    public let content: String?
    public let toolCallId: String?
    public let toolCalls: [SharedToolCall]?

    public init(role: String, content: String? = nil, toolCallId: String? = nil, toolCalls: [SharedToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    public static func system(_ text: String) -> SharedChatMessage {
        SharedChatMessage(role: "system", content: text)
    }
    public static func user(_ text: String) -> SharedChatMessage {
        SharedChatMessage(role: "user", content: text)
    }
    public static func assistant(content: String?, toolCalls: [SharedToolCall]? = nil) -> SharedChatMessage {
        SharedChatMessage(role: "assistant", content: content, toolCalls: toolCalls)
    }
    public static func tool(id: String, content: String) -> SharedChatMessage {
        SharedChatMessage(role: "tool", content: content, toolCallId: id)
    }
}

public struct SharedToolCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let function: SharedToolCallFunction

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = SharedToolCallFunction(name: name, arguments: arguments)
    }
}

public struct SharedToolCallFunction: Codable, Sendable {
    public let name: String
    public let arguments: String
}

// MARK: - Agent turn result

public struct SharedAgentTurnResult: Sendable {
    public let toolCalls: [SharedToolCall]
    public let assistantContent: String
    public let inputTokens: Int
    public let outputTokens: Int

    public init(toolCalls: [SharedToolCall], assistantContent: String, inputTokens: Int, outputTokens: Int) {
        self.toolCalls = toolCalls
        self.assistantContent = assistantContent
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

// MARK: - Build Planning Session

public enum BuildStepCategory: String, Codable, Sendable, CaseIterable {
    case algorithm
    case codeblock
    case database
    case integration
    case configuration

    public var displayName: String {
        switch self {
        case .algorithm: return "Algorithm"
        case .codeblock: return "Code Block"
        case .database: return "Database"
        case .integration: return "Integration"
        case .configuration: return "Configuration"
        }
    }
}

public struct BuildImplementationStep: Codable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var description: String
    public var category: BuildStepCategory
    public var status: BuildStepStatus
    public var resultSummary: String?

    public init(id: String = UUID().uuidString, title: String, description: String, category: BuildStepCategory) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.status = .pending
    }
}

public enum BuildStepStatus: String, Codable, Sendable {
    case pending
    case implementing
    case done
    case failed
}

public enum BuildMessageRole: String, Codable, Sendable {
    case user, assistant
}

public enum BuildResponseType: String, Codable, Sendable {
    case yesNo = "yes_no"
    case pickOne = "pick_one"
    case multiSelect = "multi_select"
}

public struct BuildMessage: Codable, Sendable, Identifiable {
    public let id: String
    public let role: BuildMessageRole
    public let content: String
    public var responseType: BuildResponseType?
    public var options: [String]?
    public var selectedOptions: [String]?

    public init(
        id: String = UUID().uuidString,
        role: BuildMessageRole,
        content: String,
        responseType: BuildResponseType? = nil,
        options: [String]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.responseType = responseType
        self.options = options
    }
}

public struct SharedBuildSession: Codable, Sendable {
    public var messages: [BuildMessage] = []
    public var architecture: String? = nil
    public var implementationSteps: [BuildImplementationStep] = []
    public var isComplete: Bool = false

    public init() {}
}

// MARK: - Build Planner Events (callback protocol)

public enum BuildPlannerEvent: Sendable {
    case question(BuildMessage, explanation: String)
    case architectureDesigned(String)
    case stepsProposed([BuildImplementationStep])
    case complete(summary: String)
    case failed(String)
    case statusUpdate(String)
}
