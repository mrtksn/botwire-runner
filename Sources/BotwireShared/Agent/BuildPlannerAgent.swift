// BuildPlannerAgent.swift
// BotwireShared
//
// Platform-agnostic Build It planner. The authored behavior is loaded from
// shared/defaults/build_tools.json by the host and passed in at construction.

import Foundation

public final class BuildPlannerAgent: @unchecked Sendable {

    public let projectName: String
    public let projectDescription: String
    public let profiles: [SharedLLMProfile]
    public var defaultProfileID: String?

    public var onEvent: (@Sendable (BuildPlannerEvent) -> Void)?

    public private(set) var session: SharedBuildSession = SharedBuildSession()

    private var currentTask: Task<Void, Never>?
    private var isCancelled = false
    private let llm = SharedLLMClient()
    private let defaults: SharedBuildPlannerDefaults?

    public init(
        projectName: String,
        projectDescription: String,
        profiles: [SharedLLMProfile],
        defaultsJSON: String,
        defaultProfileID: String? = nil
    ) {
        self.projectName = projectName
        self.projectDescription = projectDescription
        self.profiles = profiles
        self.defaultProfileID = defaultProfileID
        self.defaults = SharedBuildPlannerDefaults.decode(from: defaultsJSON)
    }

    public func start() {
        session = SharedBuildSession()
        isCancelled = false
        runTechLeadTurn()
    }

    public func respond(selectedOptions: [String]) {
        if let idx = session.messages.indices.last(where: { session.messages[$0].responseType != nil && session.messages[$0].selectedOptions == nil }) {
            session.messages[idx].selectedOptions = selectedOptions
        }
        session.messages.append(BuildMessage(role: .user, content: selectedOptions.joined(separator: ", ")))
        runTechLeadTurn()
    }

    public func cancel() {
        isCancelled = true
        currentTask?.cancel()
        currentTask = nil
    }

    private func resolveProfile() -> SharedLLMProfile? {
        if let pid = defaultProfileID, let profile = profiles.first(where: { $0.id == pid }) {
            return profile
        }
        return profiles.first
    }

    private func runTechLeadTurn() {
        currentTask?.cancel()
        isCancelled = false

        currentTask = Task {
            await self.executeTechLeadTurn()
        }
    }

    private func executeTechLeadTurn() async {
        guard !isCancelled else { return }
        guard let defaults else {
            onEvent?(.failed(""))
            return
        }

        onEvent?(.statusUpdate(defaults.messages.techLeadThinking))

        guard let profile = resolveProfile() else {
            onEvent?(.failed(defaults.messages.noLLMProfile))
            return
        }

        let messages: [SharedChatMessage] = [
            .system(render(defaults.prompts.techLeadSystem, values: ["projectName": projectName])),
            .user(buildTechLeadPrompt(defaults: defaults))
        ]

        do {
            guard !isCancelled else { return }
            let result = try await llm.complete(
                profile: profile,
                messages: messages,
                tools: SharedLLMClient.toolDefinitions(from: defaults.tools),
                maxOutputTokens: defaults.runLimits.maxOutputTokens
            )
            guard !isCancelled else { return }

            await handleTechLeadResult(result, profile: profile, defaults: defaults)
        } catch {
            guard !isCancelled else { return }
            onEvent?(.failed("\(defaults.messages.techLeadErrorPrefix) \(error.localizedDescription)"))
        }
    }

    private func handleTechLeadResult(
        _ result: SharedAgentTurnResult,
        profile: SharedLLMProfile,
        defaults: SharedBuildPlannerDefaults
    ) async {
        guard let toolCall = result.toolCalls.first else {
            onEvent?(.failed(defaults.messages.techLeadNoToolCall))
            return
        }

        guard let argsData = toolCall.function.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
            onEvent?(.failed(defaults.messages.toolArgumentsParseFailure))
            return
        }

        switch toolCall.function.name {
        case defaults.toolNames.askQuestion:
            handleQuestion(args)

        case defaults.toolNames.proposeArchitecture:
            let summary = args["requirements_summary"] as? String ?? ""
            session.messages.append(BuildMessage(role: .assistant, content: defaults.messages.architectureHandoff))
            await runArchitectTurn(requirementsSummary: summary, profile: profile, defaults: defaults)

        case defaults.toolNames.addImplementationSteps:
            handleImplementationSteps(args, defaults: defaults)

        case defaults.toolNames.finishPlanning:
            let summary = args["summary"] as? String ?? defaults.messages.planningCompleteFallback
            session.messages.append(BuildMessage(role: .assistant, content: summary))
            session.isComplete = true
            onEvent?(.complete(summary: summary))

        default:
            onEvent?(.failed("\(defaults.messages.unknownToolPrefix) \(toolCall.function.name)"))
        }
    }

    private func handleQuestion(_ args: [String: Any]) {
        let question = args["question"] as? String ?? ""
        let explanation = args["explanation"] as? String ?? ""
        let responseType = BuildResponseType(rawValue: args["response_type"] as? String ?? "") ?? .pickOne
        let options = args["options"] as? [String] ?? []

        let message = BuildMessage(role: .assistant, content: question, responseType: responseType, options: options)
        session.messages.append(message)
        onEvent?(.question(message, explanation: explanation))
    }

    private func handleImplementationSteps(_ args: [String: Any], defaults: SharedBuildPlannerDefaults) {
        guard let stepsData = args["steps"] as? [[String: Any]] else {
            runTechLeadTurn()
            return
        }

        let steps: [BuildImplementationStep] = stepsData.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let description = dict["description"] as? String,
                  let rawCategory = dict["category"] as? String,
                  let category = BuildStepCategory(rawValue: rawCategory) else {
                return nil
            }
            return BuildImplementationStep(title: title, description: description, category: category)
        }

        if steps.isEmpty {
            runTechLeadTurn()
            return
        }

        session.implementationSteps = steps
        session.messages.append(BuildMessage(role: .assistant, content: defaults.messages.stepsProposed))
        onEvent?(.stepsProposed(steps))
        runTechLeadTurn()
    }

    private func runArchitectTurn(
        requirementsSummary: String,
        profile: SharedLLMProfile,
        defaults: SharedBuildPlannerDefaults
    ) async {
        guard !isCancelled else { return }
        onEvent?(.statusUpdate(defaults.messages.architectThinking))

        let prompt = render(
            defaults.prompts.architect,
            values: [
                "startupName": projectName,
                "startupDescription": projectDescription.isEmpty ? defaults.prompts.emptyProjectDescription : projectDescription,
                "requirementsSummary": requirementsSummary
            ]
        )

        let messages: [SharedChatMessage] = [
            .system(defaults.prompts.architectSystem),
            .user(prompt)
        ]

        do {
            let result = try await llm.complete(
                profile: profile,
                messages: messages,
                tools: SharedLLMClient.toolDefinitions(from: [defaults.architectReplyTool]),
                maxOutputTokens: defaults.runLimits.maxOutputTokens
            )
            guard !isCancelled else { return }

            if let toolCall = result.toolCalls.first,
               toolCall.function.name == defaults.toolNames.replyToUser,
               let argsData = toolCall.function.arguments.data(using: .utf8),
               let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
               let architecture = args["message"] as? String {
                session.architecture = architecture
                onEvent?(.architectureDesigned(architecture))
                runTechLeadTurn()
            } else {
                onEvent?(.failed(defaults.messages.architectNoDocument))
            }
        } catch {
            guard !isCancelled else { return }
            onEvent?(.failed("\(defaults.messages.architectErrorPrefix) \(error.localizedDescription)"))
        }
    }

    private func buildTechLeadPrompt(defaults: SharedBuildPlannerDefaults) -> String {
        let prompts = defaults.prompts
        let projectDescriptionSection = render(
            prompts.techLeadProjectDescriptionSection,
            values: ["startupDescription": projectDescription.isEmpty ? prompts.emptyProjectDescription : projectDescription]
        )

        let projectIdentitySection = render(
            prompts.techLeadProjectIdentitySection,
            values: [
                "startupName": projectName,
                "startupKind": ""
            ]
        )

        let conversationSection: String
        if session.messages.isEmpty {
            conversationSection = ""
        } else {
            let lines = session.messages
                .filter { $0.responseType == nil || $0.selectedOptions != nil }
                .map { message in
                    render(
                        prompts.techLeadConversationLineTemplate,
                        values: [
                            "speaker": message.role == .assistant ? prompts.techLeadConversationAssistantLabel : prompts.techLeadConversationUserLabel,
                            "message": message.content
                        ]
                    )
                }
                .joined(separator: "\n")
            conversationSection = render(prompts.techLeadConversationSection, values: ["conversationLines": lines])
        }

        let architectureSection: String
        if let architecture = session.architecture {
            architectureSection = render(prompts.techLeadArchitectureSection, values: ["architecture": architecture])
        } else {
            architectureSection = ""
        }

        let stateInstruction: String
        if session.messages.isEmpty {
            stateInstruction = prompts.techLeadOpeningInstruction
        } else if session.architecture == nil {
            stateInstruction = prompts.techLeadContinueInstruction
        } else if session.implementationSteps.isEmpty {
            stateInstruction = prompts.techLeadStepsInstruction
        } else {
            stateInstruction = prompts.techLeadFinishInstruction
        }

        return render(
            prompts.techLead,
            values: [
                "projectDescriptionSection": projectDescriptionSection,
                "projectIdentitySection": projectIdentitySection,
                "conversationSection": conversationSection,
                "notesSection": "",
                "todosSection": "",
                "architectureSection": architectureSection,
                "stateInstruction": stateInstruction,
                "toolCallContract": prompts.techLeadToolCallContract
            ]
        )
    }

    private func render(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { partial, entry in
            partial.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }
}

private struct SharedBuildPlannerDefaults: Sendable {
    let toolNames: ToolNames
    let runLimits: RunLimits
    let messages: Messages
    let prompts: Prompts
    let tools: [SharedToolDefinition]
    let architectReplyTool: SharedToolDefinition

    static func decode(from json: String) -> SharedBuildPlannerDefaults? {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        return SharedBuildPlannerDefaults(
            toolNames: envelope.conversation.toolNames,
            runLimits: envelope.conversation.runLimits,
            messages: envelope.conversation.messages,
            prompts: envelope.conversation.prompts,
            tools: envelope.tools.map(\.toolDefinition),
            architectReplyTool: envelope.conversation.architectReplyTool.toolDefinition
        )
    }

    private struct Envelope: Decodable {
        let conversation: Conversation
        let tools: [ToolRecord]
    }

    private struct Conversation: Decodable {
        let toolNames: ToolNames
        let runLimits: RunLimits
        let messages: Messages
        let prompts: Prompts
        let architectReplyTool: ToolRecord
    }

    struct ToolNames: Decodable, Sendable {
        let askQuestion: String
        let proposeArchitecture: String
        let addImplementationSteps: String
        let finishPlanning: String
        let replyToUser: String
    }

    struct RunLimits: Decodable, Sendable {
        let maxOutputTokens: Int
    }

    struct Messages: Decodable, Sendable {
        let architectureHandoff: String
        let stepsProposed: String
        let techLeadThinking: String
        let architectThinking: String
        let noLLMProfile: String
        let techLeadErrorPrefix: String
        let architectErrorPrefix: String
        let techLeadNoToolCall: String
        let toolArgumentsParseFailure: String
        let unknownToolPrefix: String
        let planningCompleteFallback: String
        let architectNoDocument: String
    }

    struct Prompts: Decodable, Sendable {
        let techLeadSystem: String
        let architectSystem: String
        let architect: String
        let techLead: String
        let techLeadProjectDescriptionSection: String
        let techLeadProjectIdentitySection: String
        let techLeadConversationSection: String
        let techLeadConversationAssistantLabel: String
        let techLeadConversationUserLabel: String
        let techLeadConversationLineTemplate: String
        let techLeadArchitectureSection: String
        let techLeadOpeningInstruction: String
        let techLeadContinueInstruction: String
        let techLeadStepsInstruction: String
        let techLeadFinishInstruction: String
        let techLeadToolCallContract: String
        let emptyProjectDescription: String
    }

    private struct ToolRecord: Decodable {
        let name: String
        let description: String
        let isTerminal: Bool
        let schema: SharedPlannerJSONValue

        var toolDefinition: SharedToolDefinition {
            SharedToolDefinition(
                name: name,
                description: description,
                parametersJSON: schema.jsonString,
                isTerminal: isTerminal
            )
        }
    }
}

private indirect enum SharedPlannerJSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: SharedPlannerJSONValue])
    case array([SharedPlannerJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SharedPlannerJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SharedPlannerJSONValue].self))
        }
    }

    var jsonString: String {
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.jsonObject)
        case .array(let value):
            return value.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }
}
