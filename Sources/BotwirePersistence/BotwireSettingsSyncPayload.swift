import Foundation

public struct BotwireSettingsSyncPayload: Codable {
    public var llmProfiles: [StoredLLMProfile]?
    public var agentProfiles: [StoredAgentProfile]?
    public var skills: [StoredSkill]?
    public var contexts: [StoredContextDefinition]?
    
    public init(llmProfiles: [StoredLLMProfile]? = nil, agentProfiles: [StoredAgentProfile]? = nil, skills: [StoredSkill]? = nil, contexts: [StoredContextDefinition]? = nil) {
        self.llmProfiles = llmProfiles
        self.agentProfiles = agentProfiles
        self.skills = skills
        self.contexts = contexts
    }
}
