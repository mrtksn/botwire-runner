import Foundation

public struct BotwireProjectBundle: Codable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var description: String?
    public var agentBlock: BotwireAgentBlock?
    public var algorithms: [BotwireAlgorithm]
    public var metadata: [String: String]

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        description: String? = nil,
        agentBlock: BotwireAgentBlock? = nil,
        algorithms: [BotwireAlgorithm] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.agentBlock = agentBlock
        self.algorithms = algorithms
        self.metadata = metadata
    }
}

public struct BotwireAgentBlock: Codable, Sendable {
    public var id: String
    public var name: String
    public var source: String

    public init(id: String, name: String, source: String) {
        self.id = id
        self.name = name
        self.source = source
    }
}

public struct BotwireAlgorithm: Codable, Sendable {
    public var id: String
    public var name: String
    public var codeBlocks: [BotwireCodeBlock]

    public init(id: String, name: String, codeBlocks: [BotwireCodeBlock] = []) {
        self.id = id
        self.name = name
        self.codeBlocks = codeBlocks
    }
}

public struct BotwireCodeBlock: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case logic
    }

    public var id: String
    public var name: String
    public var role: Role
    public var language: String
    public var source: String

    public init(
        id: String,
        name: String,
        role: Role = .logic,
        language: String = "javascript",
        source: String
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.language = language
        self.source = source
    }
}
