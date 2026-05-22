//
//  BREPControlState.swift
//  BotwireShared
//
//  Shared BREP control-state contract for remote pause/resume/query.
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct BREPControlStateRequest: Codable, Sendable, Equatable {
    public let startupID: String
    public let isActive: Bool?

    public init(startupID: String, isActive: Bool? = nil) {
        self.startupID = startupID
        self.isActive = isActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupID = try container.decode(String.self, forKey: .startupID)
        if container.contains(.isActive) {
            isActive = try container.decode(BotwireFlexibleBool.self, forKey: .isActive).value
        } else {
            isActive = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startupID, forKey: .startupID)
        try container.encodeIfPresent(isActive, forKey: .isActive)
    }

    public func relayStringBoolBody() -> [String: String] {
        var body = ["startupID": startupID]
        if let isActive {
            body["isActive"] = isActive ? "true" : "false"
        }
        return body
    }

    public static func decode(jsonData: Data) -> BREPControlStateRequest? {
        try? JSONDecoder().decode(BREPControlStateRequest.self, from: jsonData)
    }

    public static func decode(jsonString: String) -> BREPControlStateRequest? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return decode(jsonData: data)
    }

    private enum CodingKeys: String, CodingKey {
        case startupID
        case isActive
    }
}

public struct BREPControlStateResponse: Codable, Sendable, Equatable {
    public let success: Bool
    public let startupID: String?
    public let isActive: Bool?
    public let error: String?

    public init(success: Bool, startupID: String? = nil, isActive: Bool? = nil, error: String? = nil) {
        self.success = success
        self.startupID = startupID
        self.isActive = isActive
        self.error = error
    }

    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"success":false,"error":"Failed to encode response"}"#
        }
        return string
    }
}

private struct BotwireFlexibleBool: Codable, Sendable, Equatable {
    let value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
            return
        }
        if let int = try? container.decode(Int.self) {
            value = int != 0
            return
        }
        if let string = try? container.decode(String.self) {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "active", "running":
                value = true
            case "false", "0", "no", "paused", "inactive", "stopped":
                value = false
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported boolean string: \(string)")
            }
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected bool, number, or string")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
