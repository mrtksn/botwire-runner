import Foundation

public struct StoredAgenticEngine: OxiModel {
    public static let collectionName = "agentic_engines"

    public var id: String
    public var name: String
    public var source: String
    public var isDefault: Bool
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        source: String,
        isDefault: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }
}

public struct StoredRunnerSession: OxiModel {
    public static let collectionName = "runner_sessions"

    public var id: String
    public var relayBaseURL: String
    public var runnerName: String
    public var updatedAt: Date

    public init(id: String, relayBaseURL: String, runnerName: String, updatedAt: Date = Date()) {
        self.id = id
        self.relayBaseURL = relayBaseURL
        self.runnerName = runnerName
        self.updatedAt = updatedAt
    }
}

public enum AgentModalityTag: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case image
    case audio
    case video
    case file
    case embeddings
}

public struct AgentModalitySupport: Codable, Hashable, Sendable {
    public var input: [AgentModalityTag]
    public var output: [AgentModalityTag]

    public init(
        input: [AgentModalityTag] = [.text],
        output: [AgentModalityTag] = [.text]
    ) {
        self.input = Self.normalized(input)
        self.output = Self.normalized(output)
    }

    public static var textOnly: AgentModalitySupport {
        .init(input: [.text], output: [.text])
    }

    public static var allModalities: AgentModalitySupport {
        .init(input: AgentModalityTag.allCases, output: AgentModalityTag.allCases)
    }

    public func supportsInput(_ modality: AgentModalityTag) -> Bool {
        input.contains(modality)
    }

    public func supportsOutput(_ modality: AgentModalityTag) -> Bool {
        output.contains(modality)
    }

    public func supports(input inputModality: AgentModalityTag, output outputModality: AgentModalityTag) -> Bool {
        supportsInput(inputModality) && supportsOutput(outputModality)
    }

    private static func normalized(_ values: [AgentModalityTag]) -> [AgentModalityTag] {
        var seen = Set<AgentModalityTag>()
        var ordered: [AgentModalityTag] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            ordered.append(value)
        }
        return ordered
    }
}

public enum LLMFeatureTag: String, Codable, CaseIterable, Hashable, Sendable {
    case toolCalls
    case mcp
}

public struct LLMFeatureSupport: Codable, Hashable, Sendable {
    public var tags: [LLMFeatureTag]

    public init(tags: [LLMFeatureTag]) {
        self.tags = Self.normalized(tags)
    }

    public static let all: LLMFeatureSupport = .init(tags: LLMFeatureTag.allCases)
    public static let none: LLMFeatureSupport = .init(tags: [])

    public var normalizedTags: [LLMFeatureTag] {
        Self.normalized(tags)
    }

    public func supports(_ feature: LLMFeatureTag) -> Bool {
        normalizedTags.contains(feature)
    }

    private static func normalized(_ tags: [LLMFeatureTag]) -> [LLMFeatureTag] {
        var seen = Set<LLMFeatureTag>()
        return tags.filter { seen.insert($0).inserted }
    }
}

public struct StoredLLMProfile: OxiModel {
    public static let collectionName = "llm_profiles"

    public var id: String
    public var name: String
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var proxyPath: String?
    public var featureSupport: LLMFeatureSupport
    public var modalitySupport: AgentModalitySupport
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String,
        model: String,
        proxyPath: String? = nil,
        featureSupport: LLMFeatureSupport = .all,
        modalitySupport: AgentModalitySupport = .allModalities,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.proxyPath = proxyPath
        self.featureSupport = featureSupport
        self.modalitySupport = modalitySupport
        self.updatedAt = updatedAt
    }

    public var sanitizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var sanitizedProxyPath: String? {
        let trimmed = proxyPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiKey
        case model
        case proxyPath
        case featureSupport
        case modalitySupport
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        self.apiKey = try container.decode(String.self, forKey: .apiKey)
        self.model = try container.decode(String.self, forKey: .model)
        self.proxyPath = try container.decodeIfPresent(String.self, forKey: .proxyPath)
        self.featureSupport = try container.decodeIfPresent(LLMFeatureSupport.self, forKey: .featureSupport) ?? .all
        self.modalitySupport = try container.decodeIfPresent(AgentModalitySupport.self, forKey: .modalitySupport) ?? .allModalities
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public struct StoredAgentProfile: OxiModel {
    public static let collectionName = "agent_profiles"

    public var id: String
    public var name: String
    public var agentDescription: String?
    public var typeRawValue: String
    public var systemPrompt: String
    public var toolsJSON: String
    public var contextsJSON: String?
    public var apiProfileID: String?
    public var modalitySupportJSON: String?
    public var skillIDsJSON: String?
    public var sortIndex: Int
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        agentDescription: String? = nil,
        typeRawValue: String = "general",
        systemPrompt: String = "",
        toolsJSON: String = "[]",
        contextsJSON: String? = nil,
        apiProfileID: String? = nil,
        modalitySupportJSON: String? = nil,
        skillIDsJSON: String? = nil,
        sortIndex: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.agentDescription = agentDescription
        self.typeRawValue = typeRawValue
        self.systemPrompt = systemPrompt
        self.toolsJSON = toolsJSON
        self.contextsJSON = contextsJSON
        self.apiProfileID = apiProfileID
        self.modalitySupportJSON = modalitySupportJSON
        self.skillIDsJSON = skillIDsJSON
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case user
        case agentDescription
        case description
        case typeRawValue
        case type
        case systemPrompt
        case toolsJSON
        case tools
        case contextsJSON
        case contexts
        case apiProfileID
        case modalitySupportJSON
        case modalitySupport
        case skillIDsJSON
        case skillIDs
        case sortIndex
        case updatedAt
    }

    private enum UserCodingKeys: String, CodingKey {
        case name
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)

        if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self.name = name
        } else if let user = try? container.nestedContainer(keyedBy: UserCodingKeys.self, forKey: .user),
                  let userName = try user.decodeIfPresent(String.self, forKey: .name) {
            self.name = userName
        } else {
            self.name = id
        }

        if let description = try container.decodeIfPresent(String.self, forKey: .agentDescription) {
            self.agentDescription = description
        } else if let description = try container.decodeIfPresent(String.self, forKey: .description) {
            self.agentDescription = description
        } else if let user = try? container.nestedContainer(keyedBy: UserCodingKeys.self, forKey: .user) {
            self.agentDescription = try user.decodeIfPresent(String.self, forKey: .description)
        } else {
            self.agentDescription = nil
        }

        self.typeRawValue = try container.decodeIfPresent(String.self, forKey: .typeRawValue)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? "general"
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        self.toolsJSON = try Self.decodeJSONString(from: container, stringKey: .toolsJSON, objectKey: .tools) ?? "[]"
        self.contextsJSON = try Self.decodeJSONString(from: container, stringKey: .contextsJSON, objectKey: .contexts)
        self.apiProfileID = try container.decodeIfPresent(String.self, forKey: .apiProfileID)
        self.modalitySupportJSON = try Self.decodeJSONString(from: container, stringKey: .modalitySupportJSON, objectKey: .modalitySupport)
        self.skillIDsJSON = try Self.decodeJSONString(from: container, stringKey: .skillIDsJSON, objectKey: .skillIDs)
        self.sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(agentDescription, forKey: .agentDescription)
        try container.encode(typeRawValue, forKey: .typeRawValue)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(toolsJSON, forKey: .toolsJSON)
        try container.encodeIfPresent(contextsJSON, forKey: .contextsJSON)
        try container.encodeIfPresent(apiProfileID, forKey: .apiProfileID)
        try container.encodeIfPresent(modalitySupportJSON, forKey: .modalitySupportJSON)
        try container.encodeIfPresent(skillIDsJSON, forKey: .skillIDsJSON)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func decodeJSONString(
        from container: KeyedDecodingContainer<CodingKeys>,
        stringKey: CodingKeys,
        objectKey: CodingKeys
    ) throws -> String? {
        if let value = try container.decodeIfPresent(String.self, forKey: stringKey) {
            return value
        }
        guard container.contains(objectKey) else {
            return nil
        }
        let value = try container.decode(AnyCodableJSON.self, forKey: objectKey)
        return value.encodedString
    }
}

public struct StoredSkill: OxiModel {
    public static let collectionName = "agent_skills"

    public var id: String
    public var name: String
    public var skillDescription: String
    public var markdown: String
    public var isGenerated: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        skillDescription: String,
        markdown: String,
        isGenerated: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.skillDescription = skillDescription
        self.markdown = markdown
        self.isGenerated = isGenerated
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case skillDescription
        case markdown
        case isGenerated
        case sortIndex
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeLossyString(forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.skillDescription = try container.decodeIfPresent(String.self, forKey: .skillDescription) ?? ""
        self.markdown = try container.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        self.isGenerated = try container.decodeIfPresent(Bool.self, forKey: .isGenerated) ?? false
        self.sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(skillDescription, forKey: .skillDescription)
        try container.encode(markdown, forKey: .markdown)
        try container.encode(isGenerated, forKey: .isGenerated)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct StoredContextDefinition: OxiModel {
    public static let collectionName = "agent_contexts"

    public var id: String // mapping to 'key'
    public var name: String
    public var contextDescription: String
    public var content: String
    public var scriptSource: String?
    public var executionModeRawValue: String
    public var isEnabled: Bool
    public var isDefault: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        contextDescription: String,
        content: String,
        scriptSource: String? = nil,
        executionModeRawValue: String = "staticText",
        isEnabled: Bool = true,
        isDefault: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.contextDescription = contextDescription
        self.content = content
        self.scriptSource = scriptSource
        self.executionModeRawValue = executionModeRawValue
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case name
        case contextDescription
        case content
        case scriptSource
        case executionModeRawValue
        case executionMode
        case isEnabled
        case isDefault
        case sortIndex
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decode(String.self, forKey: .key)
        self.name = try container.decode(String.self, forKey: .name)
        self.contextDescription = try container.decodeIfPresent(String.self, forKey: .contextDescription) ?? ""
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        let script = try container.decodeIfPresent(String.self, forKey: .scriptSource)
        self.scriptSource = (script?.isEmpty ?? true) ? nil : script
        self.executionModeRawValue = try container.decodeIfPresent(String.self, forKey: .executionModeRawValue)
            ?? container.decodeIfPresent(String.self, forKey: .executionMode)
            ?? "staticText"
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(contextDescription, forKey: .contextDescription)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(scriptSource, forKey: .scriptSource)
        try container.encode(executionModeRawValue, forKey: .executionModeRawValue)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

private struct AnyCodableJSON: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var values: [Any] = []
            while !array.isAtEnd {
                values.append(try array.decode(AnyCodableJSON.self).value)
            }
            self.value = values
            return
        }

        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var values: [String: Any] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(AnyCodableJSON.self, forKey: key).value
            }
            self.value = values
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self.value = NSNull()
        } else if let value = try? single.decode(Bool.self) {
            self.value = value
        } else if let value = try? single.decode(Int.self) {
            self.value = value
        } else if let value = try? single.decode(Double.self) {
            self.value = value
        } else {
            self.value = try single.decode(String.self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        if value is NSNull {
            try single.encodeNil()
        } else if let value = value as? Bool {
            try single.encode(value)
        } else if let value = value as? Int {
            try single.encode(value)
        } else if let value = value as? Double {
            try single.encode(value)
        } else if let value = value as? String {
            try single.encode(value)
        } else if let value = value as? [Any] {
            var array = encoder.unkeyedContainer()
            for item in value {
                try array.encode(AnyCodableJSON(value: item))
            }
        } else if let value = value as? [String: Any] {
            var object = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, item) in value {
                try object.encode(AnyCodableJSON(value: item), forKey: DynamicCodingKey(stringValue: key)!)
            }
        } else {
            try single.encodeNil()
        }
    }

    init(value: Any) {
        self.value = value
    }

    var encodedString: String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(UUID.self, forKey: key) {
            return value.uuidString
        }
        return try decode(String.self, forKey: key)
    }
}
