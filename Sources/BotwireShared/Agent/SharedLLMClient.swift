// SharedLLMClient.swift
// BotwireShared
//
// Minimal OpenAI-compatible LLM client using Foundation URLSession.
// Works on Apple platforms and Linux.
// Android uses the host WebView/Kotlin networking bridge instead of linking
// Swift FoundationNetworking into the JNI library.
// No streaming required - the DefaultAgentBlockScript uses fetch() via Botwire.fetch
// for streaming; this client is for native agent orchestration (Build planner etc.).

import Foundation
#if canImport(FoundationNetworking) && !os(Android)
import FoundationNetworking
#endif

public enum SharedLLMClientError: Error, LocalizedError {
    case unavailable(String)
    case httpError(Int, body: String)
    case invalidResponse
    case decodingError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .invalidResponse: return "Invalid HTTP response"
        case .decodingError(let msg): return "Decode error: \(msg)"
        case .cancelled: return "Request cancelled"
        }
    }
}

public struct SharedLLMClient: Sendable {

    public init() {}

    /// Send a non-streaming chat completion request.
    /// Returns the assistant message, tool calls, and token usage.
    public func complete(
        profile: SharedLLMProfile,
        messages: [SharedChatMessage],
        tools: [[String: Any]],
        maxOutputTokens: Int
    ) async throws -> SharedAgentTurnResult {
        #if os(Android)
        throw SharedLLMClientError.unavailable(
            "Native Swift LLM networking is unavailable on Android. Use the Android Botwire.agent/Botwire.fetch host bridge."
        )
        #else

        var requestBody: [String: Any] = [
            "model": profile.model,
            "messages": messages.map(Self.messageToDictionary),
            "temperature": 0.35,
            "stream": false
        ]

        if !tools.isEmpty {
            requestBody["tools"] = tools
            requestBody["tool_choice"] = "auto"
        }

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: profile.completionsURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(profile.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SharedLLMClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SharedLLMClientError.httpError(http.statusCode, body: body)
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SharedLLMClientError.decodingError("Could not parse response JSON")
        }

        let usage = parsed["usage"] as? [String: Any]
        let inputTokens = (usage?["prompt_tokens"] as? Int) ?? (usage?["input_tokens"] as? Int) ?? 0
        let outputTokens = (usage?["completion_tokens"] as? Int) ?? (usage?["output_tokens"] as? Int) ?? 0

        let choices = parsed["choices"] as? [[String: Any]]
        let choice = choices?.first
        let message = choice?["message"] as? [String: Any]
        let assistantContent = message?["content"] as? String ?? ""
        let rawToolCalls = message?["tool_calls"] as? [[String: Any]] ?? []

        let toolCalls: [SharedToolCall] = rawToolCalls.compactMap { tc in
            guard let id = tc["id"] as? String,
                  let fn = tc["function"] as? [String: Any],
                  let name = fn["name"] as? String,
                  let args = fn["arguments"] as? String else { return nil }
            return SharedToolCall(id: id, name: name, arguments: args)
        }

        return SharedAgentTurnResult(
            toolCalls: toolCalls,
            assistantContent: assistantContent,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        #endif
    }

    /// Convert a SharedChatMessage to a dictionary for JSON serialization.
    static func messageToDictionary(_ msg: SharedChatMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": msg.role]
        if let content = msg.content { dict["content"] = content }
        if let toolCallId = msg.toolCallId { dict["tool_call_id"] = toolCallId }
        if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
            dict["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                ["id": tc.id, "type": tc.type, "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
            }
        }
        return dict
    }

    /// Build OpenAI-compatible tool definition dictionaries from SharedToolDefinition array.
    public static func toolDefinitions(from tools: [SharedToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            let params: Any = {
                guard let data = tool.parametersJSON.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) else {
                    return ["type": "object", "properties": [String: Any]()]
                }
                return obj
            }()
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": params
                ] as [String: Any]
            ]
        }
    }
}
