import Foundation

public enum BotwireCanonicalSnapshotRoundTrip {
    public static let metadataKey = "__botwire.originalStartupSnapshot"

    public static func store(startupSnapshot: [String: Any], in metadata: inout [String: String]) {
        metadata[metadataKey] = jsonString(startupSnapshot)
    }

    public static func originalStartupSnapshot(in metadata: [String: String]) -> [String: Any]? {
        metadata[metadataKey].flatMap(jsonObject)
    }

    public static func startupSnapshot(
        original: [String: Any]?,
        id: String,
        name: String,
        description: String?,
        algorithms: [[String: Any]],
        date: Date = Date()
    ) -> [String: Any] {
        var snapshot = original ?? legacyStartupSnapshot(
            id: id,
            name: name,
            description: description,
            algorithms: algorithms,
            date: date
        )

        snapshot["id"] = id
        snapshot["kind"] = snapshot["kind"] ?? "startup"
        snapshot["name"] = name
        snapshot["description"] = description ?? ""
        snapshot["logo"] = snapshot["logo"] ?? ""
        snapshot["logoDescription"] = snapshot["logoDescription"] ?? ""
        snapshot["createdAt"] = snapshot["createdAt"] ?? date.timeIntervalSinceReferenceDate
        snapshot["lastModified"] = snapshot["lastModified"] ?? date.timeIntervalSinceReferenceDate
        snapshot["notes"] = snapshot["notes"] ?? []
        snapshot["todos"] = snapshot["todos"] ?? []
        snapshot["projectDatabases"] = snapshot["projectDatabases"] ?? []
        snapshot["databaseAccessGrants"] = snapshot["databaseAccessGrants"] ?? []
        snapshot["projectFiles"] = snapshot["projectFiles"] ?? []
        snapshot["fileAccessGrants"] = snapshot["fileAccessGrants"] ?? []
        snapshot["httpUsers"] = snapshot["httpUsers"] ?? []
        snapshot["httpAccessTokens"] = snapshot["httpAccessTokens"] ?? []
        snapshot["httpAccessRequests"] = snapshot["httpAccessRequests"] ?? []
        snapshot["algorithms"] = algorithms
        return snapshot
    }

    public static func algorithmSnapshot(
        original: [String: Any]?,
        id: String,
        name: String,
        description: String?,
        entryPointRawValue: String?,
        httpConfig: [String: Any]?,
        dataWatchRules: [[String: Any]],
        timerProperty: [String: Any]?,
        codeblocks: [[String: Any]]
    ) -> [String: Any] {
        var snapshot = original ?? legacyAlgorithmSnapshot(
            id: id,
            name: name,
            description: description,
            entryPointRawValue: entryPointRawValue,
            codeblocks: codeblocks
        )

        snapshot["id"] = id
        snapshot["name"] = name
        snapshot["description"] = description ?? (snapshot["description"] as? String ?? "")
        snapshot["entryPointRawValue"] = entryPointRawValue ?? (snapshot["entryPointRawValue"] as? String ?? "manual")
        if let httpConfig { snapshot["httpConfig"] = httpConfig }
        snapshot["dataWatchRules"] = dataWatchRules
        if let timerProperty { snapshot["timerProperty"] = timerProperty }
        snapshot["codeblocks"] = codeblocks
        return snapshot
    }

    public static func codeBlockSnapshot(
        original: [String: Any]?,
        id: String,
        name: String,
        role: String,
        language: String,
        code: String,
        date: Date = Date()
    ) -> [String: Any] {
        var snapshot = original ?? legacyCodeBlockSnapshot(
            id: id,
            name: name,
            role: role,
            language: language,
            code: code,
            date: date
        )

        snapshot["id"] = id
        snapshot["name"] = name
        snapshot["role"] = role
        snapshot["action"] = snapshot["action"] ?? "run"
        snapshot["kind"] = snapshot["kind"] ?? "standard"
        snapshot["description"] = snapshot["description"] ?? ""
        snapshot["algorithmDatabases"] = snapshot["algorithmDatabases"] ?? []
        snapshot["codeData"] = [
            "language": language,
            "code": code
        ]
        snapshot["date"] = snapshot["date"] ?? date.timeIntervalSinceReferenceDate
        return snapshot
    }

    public static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func jsonString(_ object: Any) -> String {
        guard let compatibleObject = jsonCompatibleObject(object),
              JSONSerialization.isValidJSONObject(compatibleObject),
              let data = try? JSONSerialization.data(withJSONObject: compatibleObject, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func jsonCompatibleObject(_ value: Any) -> Any? {
        if let value = value as? [String: Any] {
            return Dictionary(
                uniqueKeysWithValues: value.compactMap { key, nestedValue in
                    jsonCompatibleObject(nestedValue).map { (key, $0) }
                }
            )
        }

        if let value = value as? [Any] {
            return value.map { jsonCompatibleObject($0) ?? NSNull() }
        }

        if value is NSNull {
            return NSNull()
        }

        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Int8:
            return Int(value)
        case let value as Int16:
            return Int(value)
        case let value as Int32:
            return Int(value)
        case let value as Int64:
            return value
        case let value as UInt:
            return value
        case let value as UInt8:
            return Int(value)
        case let value as UInt16:
            return Int(value)
        case let value as UInt32:
            return Int64(value)
        case let value as UInt64:
            return value <= UInt64(Int64.max) ? Int64(value) : String(value)
        case let value as Float:
            return value.isFinite ? Double(value) : nil
        case let value as Double:
            return value.isFinite ? value : nil
        case let value as Decimal:
            return NSDecimalNumber(decimal: value)
        case let value as NSNumber:
            return value
        case let value as Date:
            return value.timeIntervalSinceReferenceDate
        case let value as UUID:
            return value.uuidString
        case let value as Data:
            return value.base64EncodedString()
        case let value as URL:
            return value.absoluteString
        default:
            return nil
        }
    }

    private static func legacyStartupSnapshot(
        id: String,
        name: String,
        description: String?,
        algorithms: [[String: Any]],
        date: Date
    ) -> [String: Any] {
        [
            "id": id,
            "kind": "startup",
            "name": name,
            "description": description ?? "",
            "logo": "",
            "logoDescription": "",
            "createdAt": date.timeIntervalSinceReferenceDate,
            "lastModified": date.timeIntervalSinceReferenceDate,
            "notes": [],
            "todos": [],
            "algorithms": algorithms,
            "projectDatabases": [],
            "databaseAccessGrants": [],
            "projectFiles": [],
            "fileAccessGrants": [],
            "httpUsers": [],
            "httpAccessTokens": [],
            "httpAccessRequests": []
        ]
    }

    private static func legacyAlgorithmSnapshot(
        id: String,
        name: String,
        description: String?,
        entryPointRawValue: String?,
        codeblocks: [[String: Any]]
    ) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "description": description ?? "",
            "entryPointRawValue": entryPointRawValue ?? "manual",
            "dataWatchRules": [],
            "codeblocks": codeblocks
        ]
    }

    private static func legacyCodeBlockSnapshot(
        id: String,
        name: String,
        role: String,
        language: String,
        code: String,
        date: Date
    ) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "action": "run",
            "role": role,
            "kind": "standard",
            "description": "",
            "algorithmDatabases": [],
            "codeData": [
                "language": language,
                "code": code
            ],
            "date": date.timeIntervalSinceReferenceDate
        ]
    }
}
