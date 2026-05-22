import BotwireCore
import BotwirePersistence
import BotwireRuntime
import Foundation

struct LinuxDataWatchRule: Codable, Sendable {
    var collection: String
    var operation: String?
    var operations: [String]?
    var documentID: String?
    var propertyPath: String?
    var queryJSON: String?
    var databaseName: String?
}

enum LinuxDataWatchRunner {
    static func handle(event: BotwireDatabaseMutationEvent, workspacePath: String?) async {
        let store = CloudResourceStore(workspacePath: workspacePath)
        guard let bundle = try? await store.project(startupID: event.projectID) else { return }

        for algorithm in bundle.algorithms where dataWatchEntryPoint(for: algorithm.id, in: bundle) {
            if algorithm.id == event.sourceAlgorithmID {
                continue
            }
            let rules = dataWatchRules(for: algorithm.id, in: bundle)
            guard await shouldRun(event: event, rules: rules, workspacePath: workspacePath) else { continue }
            guard let codeBlock = algorithm.codeBlocks.first(where: { $0.role == .logic }) else {
                BotwireRunnerCLI.emitCloudEvent("datawatch.skipped", [
                    "startupID": event.projectID,
                    "algorithmID": algorithm.id,
                    "reason": "No executable logic codeblock"
                ])
                continue
            }

            let result = await CloudExecutionResultFactory.executeCodeBlock(
                startupID: event.projectID,
                algorithmID: algorithm.id,
                codeBlock: codeBlock,
                inputJSON: inputJSON(for: event),
                workspacePath: workspacePath,
                runID: UUID().uuidString,
                trigger: "dataWatch",
                traceStore: store
            )
            BotwireRunnerCLI.emitCloudEvent(result.success ? "datawatch.finished" : "datawatch.failed", [
                "startupID": event.projectID,
                "algorithmID": algorithm.id,
                "collection": event.collection,
                "operation": event.operation,
                "success": result.success,
                "error": result.reports.first?.error?.message as Any
            ])
        }
    }

    static func storeDataWatchMetadata(from algorithmSnapshot: [String: Any], algorithmID: String, into metadata: inout [String: String]) {
        let entryPoint = (algorithmSnapshot["entryPointRawValue"] as? String) ?? "manual"
        guard entryPoint == "dataWatch" else { return }
        let rules = algorithmSnapshot["dataWatchRules"] as? [[String: Any]] ?? []
        metadata["algorithm.\(algorithmID).dataWatchRules"] = botwireJSONString(rules)
    }

    static func dataWatchSnapshotPayload(for algorithmID: String, in bundle: BotwireProjectBundle) -> [[String: Any]] {
        guard let json = bundle.metadata["algorithm.\(algorithmID).dataWatchRules"],
              let data = json.data(using: .utf8),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rules
    }

    private static func dataWatchEntryPoint(for algorithmID: String, in bundle: BotwireProjectBundle) -> Bool {
        bundle.metadata["algorithm.\(algorithmID).entryPoint"] == "dataWatch"
    }

    private static func dataWatchRules(for algorithmID: String, in bundle: BotwireProjectBundle) -> [LinuxDataWatchRule] {
        guard let json = bundle.metadata["algorithm.\(algorithmID).dataWatchRules"],
              let data = json.data(using: .utf8),
              let payloads = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return payloads.compactMap { payload in
            guard let collection = payload["collection"] as? String,
                  !collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let operations = (payload["operations"] as? [Any])?.compactMap { $0 as? String }
            let documentID = payload["documentID"].map { String(describing: $0) }
            return LinuxDataWatchRule(
                collection: collection,
                operation: payload["operation"] as? String,
                operations: operations,
                documentID: documentID,
                propertyPath: payload["propertyPath"] as? String,
                queryJSON: payload["queryJSON"] as? String,
                databaseName: payload["databaseName"] as? String
            )
        }
    }

    private static func shouldRun(event: BotwireDatabaseMutationEvent, rules: [LinuxDataWatchRule], workspacePath: String?) async -> Bool {
        guard !rules.isEmpty else { return true }

        for rule in rules {
            guard rule.collection.caseInsensitiveCompare(event.collection) == .orderedSame else { continue }

            if let databaseName = rule.databaseName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !databaseName.isEmpty {
                guard let eventDatabase = event.databaseName,
                      eventDatabase.caseInsensitiveCompare(databaseName) == .orderedSame else {
                    continue
                }
            }

            let allowedOperations = normalizedOperations(rule)
            if !allowedOperations.isEmpty,
               !allowedOperations.contains("any"),
               !allowedOperations.contains(event.operation) {
                continue
            }

            if let documentID = rule.documentID,
               !event.documentIDs.contains(where: { $0 == documentID }) {
                continue
            }

            if let propertyPath = rule.propertyPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !propertyPath.isEmpty,
               !event.touchedPropertyPaths.contains(where: { propertyPathMatches(rulePath: propertyPath, eventPath: $0) }) {
                continue
            }

            if let queryJSON = rule.queryJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
               !queryJSON.isEmpty,
               !(await eventMatchesQuery(event: event, queryJSON: queryJSON, workspacePath: workspacePath)) {
                continue
            }

            return true
        }

        return false
    }

    private static func normalizedOperations(_ rule: LinuxDataWatchRule) -> Set<String> {
        let operations = rule.operations ?? rule.operation.map { [$0] } ?? []
        return Set(operations.map { operation in
            let value = operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value == "insert_many" ? "insert" : value
        })
    }

    private static func eventMatchesQuery(event: BotwireDatabaseMutationEvent, queryJSON: String, workspacePath: String?) async -> Bool {
        guard !event.documentIDs.isEmpty,
              let queryData = queryJSON.data(using: .utf8),
              let query = try? JSONSerialization.jsonObject(with: queryData) as? [String: Any] else {
            return false
        }

        let dbPath: URL
        if let databaseID = event.databaseID {
            let workspace = workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace"
            dbPath = URL(fileURLWithPath: workspace)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(event.projectID, isDirectory: true)
                .appendingPathComponent("databases", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
        } else if let workspacePath {
            dbPath = URL(fileURLWithPath: workspacePath)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(event.projectID, isDirectory: true)
                .appendingPathComponent("data.oxidb")
        } else {
            dbPath = URL(fileURLWithPath: "/tmp/botwire_projects/\(event.projectID)/data.oxidb")
        }

        let store = OxiDBEmbeddedStore(root: dbPath)
        defer { store.close() }
        guard let result = try? store.execute(command: [
            "cmd": "find",
            "collection": event.collection,
            "query": query
        ]),
              let rows = result["data"] as? [[String: Any]] else {
            return false
        }

        let changedIDs = Set(event.documentIDs)
        return rows.contains { row in
            guard let id = row["_id"] else { return false }
            return changedIDs.contains(String(describing: id))
        }
    }

    private static func propertyPathMatches(rulePath: String, eventPath: String) -> Bool {
        if rulePath == eventPath { return true }
        if rulePath.hasPrefix(eventPath + ".") || eventPath.hasPrefix(rulePath + ".") { return true }
        let ruleLeaf = rulePath.split(separator: ".").last.map(String.init) ?? rulePath
        let eventLeaf = eventPath.split(separator: ".").last.map(String.init) ?? eventPath
        return ruleLeaf == eventLeaf
    }

    private static func inputJSON(for event: BotwireDatabaseMutationEvent) -> String? {
        let object: [String: Any] = [
            "source": "database_watch",
            "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
            "startupID": event.projectID,
            "database": [
                "id": event.databaseID.map { $0 as Any } ?? NSNull(),
                "name": event.databaseName.map { $0 as Any } ?? NSNull()
            ],
            "event": [
                "collection": event.collection,
                "operation": event.operation,
                "rawOperation": event.rawOperation,
                "documentIDs": event.documentIDs,
                "touchedPropertyPaths": event.touchedPropertyPaths,
                "sourceAlgorithmID": event.sourceAlgorithmID.map { $0 as Any } ?? NSNull(),
                "sourceCodeBlockID": event.sourceCodeBlockID.map { $0 as Any } ?? NSNull()
            ]
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
