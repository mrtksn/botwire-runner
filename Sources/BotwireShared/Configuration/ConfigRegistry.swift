//
//  ConfigRegistry.swift
//  BotwireShared
//
//  Centralized configuration registry core — platform-agnostic definition.
//  Every configurable setting registers here with a typed getter/setter.
//  Shared across iOS, macOS, Linux, and Android.
//

#if canImport(Combine)
import Combine
#endif
import Foundation

public enum ConfigValueType: String, Codable, CaseIterable {
    case string
    case int
    case bool
    case double
    case stringArray
}

public enum ConfigValue: Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)
    case stringArray([String])
    case null

    public var type: ConfigValueType? {
        switch self {
        case .string: return .string
        case .int: return .int
        case .bool: return .bool
        case .double: return .double
        case .stringArray: return .stringArray
        case .null: return nil
        }
    }

    public var asJSON: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .bool(let v): return v
        case .double(let v): return v
        case .stringArray(let v): return v
        case .null: return NSNull()
        }
    }

    public var displayString: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return "\(v)"
        case .bool(let v): return v ? "true" : "false"
        case .double(let v): return "\(v)"
        case .stringArray(let v): return v.joined(separator: ", ")
        case .null: return "(not set)"
        }
    }

    public static func from(json: Any, expectedType: ConfigValueType) -> ConfigValue? {
        switch expectedType {
        case .string:
            if let v = json as? String { return .string(v) }
        case .int:
            if let v = json as? Int { return .int(v) }
            if let v = json as? Double, v == v.rounded() { return .int(Int(v)) }
        case .bool:
            if let v = json as? Bool { return .bool(v) }
            if let v = json as? Int { return .bool(v != 0) }
        case .double:
            if let v = json as? Double { return .double(v) }
            if let v = json as? Int { return .double(Double(v)) }
        case .stringArray:
            if let v = json as? [String] { return .stringArray(v) }
        }
        return nil
    }
}

public enum ConfigCategory: String, CaseIterable, Codable {
    case project = "Project"
    case agentEngine = "Agent Engine"
    case runtime = "Runtime"
    case observability = "Observability"
    case buildPipeline = "Build Pipeline"
    case developPipeline = "Develop Pipeline"
    case agentProfiles = "Agent Profiles"
    case llmProfiles = "LLM Profiles"

    public var displayName: String { rawValue }

    public var sortOrder: Int {
        switch self {
        case .project: return 0
        case .agentEngine: return 1
        case .runtime: return 2
        case .observability: return 3
        case .buildPipeline: return 4
        case .developPipeline: return 5
        case .agentProfiles: return 6
        case .llmProfiles: return 7
        }
    }
}

public struct ConfigEntryDefinition {
    public let key: String
    public let category: ConfigCategory
    public let displayName: String
    public let description: String
    public let valueType: ConfigValueType
    public let defaultValue: ConfigValue
    public let isReadOnly: Bool
    public let isSensitive: Bool
    public let validationHint: String?

    public init(
        key: String,
        category: ConfigCategory,
        displayName: String,
        description: String,
        valueType: ConfigValueType,
        defaultValue: ConfigValue,
        isReadOnly: Bool = false,
        isSensitive: Bool = false,
        validationHint: String? = nil
    ) {
        self.key = key
        self.category = category
        self.displayName = displayName
        self.description = description
        self.valueType = valueType
        self.defaultValue = defaultValue
        self.isReadOnly = isReadOnly
        self.isSensitive = isSensitive
        self.validationHint = validationHint
    }
}

public enum ConfigError: Error, LocalizedError {
    case unknownKey(String)
    case readOnly(String)
    case typeMismatch(key: String, expected: ConfigValueType, got: ConfigValueType?)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let key): return "Unknown config key: '\(key)'"
        case .readOnly(let key): return "Config key '\(key)' is read-only."
        case .typeMismatch(let key, let expected, let got):
            return "Type mismatch for '\(key)': expected \(expected.rawValue), got \(got?.rawValue ?? "null")"
        case .validationFailed(let msg): return msg
        }
    }
}

#if canImport(Combine)
@MainActor
public class ConfigRegistry: ObservableObject {
    public static let shared = ConfigRegistry()

    @Published public var lastModified: Date = .now

    private struct RegisteredEntry {
        let definition: ConfigEntryDefinition
        let getter: () -> ConfigValue
        let setter: ((ConfigValue) -> Bool)?
    }

    private var orderedKeys: [String] = []
    private var entries: [String: RegisteredEntry] = [:]

    public init() {}

    public func register(
        _ definition: ConfigEntryDefinition,
        getter: @escaping () -> ConfigValue,
        setter: ((ConfigValue) -> Bool)? = nil
    ) {
        let entry = RegisteredEntry(
            definition: definition,
            getter: getter,
            setter: definition.isReadOnly ? nil : setter
        )
        if entries[definition.key] == nil {
            orderedKeys.append(definition.key)
        }
        entries[definition.key] = entry
        objectWillChange.send()
    }

    public func unregister(prefix: String) {
        let keysToRemove = orderedKeys.filter { $0.hasPrefix(prefix) }
        for key in keysToRemove {
            entries.removeValue(forKey: key)
        }
        orderedKeys.removeAll { $0.hasPrefix(prefix) }
        objectWillChange.send()
    }

    public func get(_ key: String) -> ConfigValue {
        guard let entry = entries[key] else { return .null }
        return entry.getter()
    }

    public func getDefinition(_ key: String) -> ConfigEntryDefinition? {
        entries[key]?.definition
    }

    public func allEntries() -> [(definition: ConfigEntryDefinition, value: ConfigValue)] {
        orderedKeys.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return (entry.definition, entry.getter())
        }
    }

    public func entries(in category: ConfigCategory) -> [(definition: ConfigEntryDefinition, value: ConfigValue)] {
        allEntries().filter { $0.definition.category == category }
    }

    public func search(_ query: String) -> [(definition: ConfigEntryDefinition, value: ConfigValue)] {
        let q = query.lowercased()
        return allEntries().filter { entry in
            entry.definition.key.lowercased().contains(q) ||
            entry.definition.displayName.lowercased().contains(q) ||
            entry.definition.description.lowercased().contains(q)
        }
    }

    public var categories: [ConfigCategory] {
        let present = Set(allEntries().map(\.definition.category))
        return ConfigCategory.allCases
            .filter { present.contains($0) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    public var entryCount: Int { entries.count }

    @discardableResult
    public func set(_ key: String, value: ConfigValue) -> Result<Void, ConfigError> {
        guard let entry = entries[key] else {
            return .failure(.unknownKey(key))
        }
        if entry.definition.isReadOnly || entry.setter == nil {
            return .failure(.readOnly(key))
        }
        if let valueType = value.type, valueType != entry.definition.valueType {
            return .failure(.typeMismatch(
                key: key,
                expected: entry.definition.valueType,
                got: valueType
            ))
        }
        guard entry.setter?(value) == true else {
            return .failure(.validationFailed("Setter rejected value for '\(key)'."))
        }
        lastModified = .now
        return .success(())
    }

    @discardableResult
    public func reset(_ key: String) -> Result<Void, ConfigError> {
        guard let entry = entries[key] else {
            return .failure(.unknownKey(key))
        }
        return set(key, value: entry.definition.defaultValue)
    }

    public func entryToJSON(_ def: ConfigEntryDefinition, value: ConfigValue, redactSensitive: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "key": def.key,
            "category": def.category.rawValue,
            "displayName": def.displayName,
            "description": def.description,
            "type": def.valueType.rawValue,
            "default": def.defaultValue.asJSON,
            "readOnly": def.isReadOnly,
            "sensitive": def.isSensitive
        ]
        if let hint = def.validationHint {
            dict["validationHint"] = hint
        }
        if redactSensitive && def.isSensitive {
            if case .string(let s) = value {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 8 {
                    dict["value"] = "\(String(trimmed.prefix(4)))…\(String(trimmed.suffix(4)))"
                } else {
                    dict["value"] = trimmed.isEmpty ? "(empty)" : "****"
                }
            } else {
                dict["value"] = "****"
            }
        } else {
            dict["value"] = value.asJSON
        }
        let isDefault = value == def.defaultValue
        dict["isDefault"] = isDefault
        return dict
    }
}
#else
public class ConfigRegistry {
    public static let shared = ConfigRegistry()

    public var lastModified: Date = Date()

    private struct RegisteredEntry {
        let definition: ConfigEntryDefinition
        let getter: () -> ConfigValue
        let setter: ((ConfigValue) -> Bool)?
    }

    private var orderedKeys: [String] = []
    private var entries: [String: RegisteredEntry] = [:]

    public init() {}

    public func register(
        _ definition: ConfigEntryDefinition,
        getter: @escaping () -> ConfigValue,
        setter: ((ConfigValue) -> Bool)? = nil
    ) {
        let entry = RegisteredEntry(
            definition: definition,
            getter: getter,
            setter: definition.isReadOnly ? nil : setter
        )
        if entries[definition.key] == nil {
            orderedKeys.append(definition.key)
        }
        entries[definition.key] = entry
    }

    public func unregister(prefix: String) {
        let keysToRemove = orderedKeys.filter { $0.hasPrefix(prefix) }
        for key in keysToRemove {
            entries.removeValue(forKey: key)
        }
        orderedKeys.removeAll { $0.hasPrefix(prefix) }
    }

    public func get(_ key: String) -> ConfigValue {
        guard let entry = entries[key] else { return .null }
        return entry.getter()
    }

    public func getDefinition(_ key: String) -> ConfigEntryDefinition? {
        entries[key]?.definition
    }

    public func allEntries() -> [(definition: ConfigEntryDefinition, value: ConfigValue)] {
        orderedKeys.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return (entry.definition, entry.getter())
        }
    }

    public func entries(in category: ConfigCategory) -> [(definition: ConfigEntryDefinition, value: ConfigValue)] {
        allEntries().filter { $0.definition.category == category }
    }

    public func search(_ query: String) -> [(definition: ConfigEntryDefinition, value: ConfigValue)] {
        let q = query.lowercased()
        return allEntries().filter { entry in
            entry.definition.key.lowercased().contains(q) ||
            entry.definition.displayName.lowercased().contains(q) ||
            entry.definition.description.lowercased().contains(q)
        }
    }

    public var categories: [ConfigCategory] {
        let present = Set(allEntries().map(\.definition.category))
        return ConfigCategory.allCases
            .filter { present.contains($0) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    public var entryCount: Int { entries.count }

    @discardableResult
    public func set(_ key: String, value: ConfigValue) -> Result<Void, ConfigError> {
        guard let entry = entries[key] else {
            return .failure(.unknownKey(key))
        }
        if entry.definition.isReadOnly || entry.setter == nil {
            return .failure(.readOnly(key))
        }
        if let valueType = value.type, valueType != entry.definition.valueType {
            return .failure(.typeMismatch(
                key: key,
                expected: entry.definition.valueType,
                got: valueType
            ))
        }
        guard entry.setter?(value) == true else {
            return .failure(.validationFailed("Setter rejected value for '\(key)'."))
        }
        lastModified = Date()
        return .success(())
    }

    @discardableResult
    public func reset(_ key: String) -> Result<Void, ConfigError> {
        guard let entry = entries[key] else {
            return .failure(.unknownKey(key))
        }
        return set(key, value: entry.definition.defaultValue)
    }

    public func entryToJSON(_ def: ConfigEntryDefinition, value: ConfigValue, redactSensitive: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "key": def.key,
            "category": def.category.rawValue,
            "displayName": def.displayName,
            "description": def.description,
            "type": def.valueType.rawValue,
            "default": def.defaultValue.asJSON,
            "readOnly": def.isReadOnly,
            "sensitive": def.isSensitive
        ]
        if let hint = def.validationHint {
            dict["validationHint"] = hint
        }
        if redactSensitive && def.isSensitive {
            if case .string(let s) = value {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 8 {
                    dict["value"] = "\(String(trimmed.prefix(4)))…\(String(trimmed.suffix(4)))"
                } else {
                    dict["value"] = trimmed.isEmpty ? "(empty)" : "****"
                }
            } else {
                dict["value"] = "****"
            }
        } else {
            dict["value"] = value.asJSON
        }
        let isDefault = value == def.defaultValue
        dict["isDefault"] = isDefault
        return dict
    }
}
#endif
