//
//  LinuxBusSupport.swift
//  BotwireRunner
//
//  Bus message types compatible with the iOS BusMessage format.
//  Uses the same JSON wire format so messages are interoperable.
//

import Foundation
import BotwireCore
import BotwireShared
import BotwireRelay
import BotwireRuntime
import BotwirePersistence

// MARK: - Wire-compatible Bus Types

typealias LinuxBusMessage = BotwireBusMessage
typealias LinuxBusResponse = BotwireBusResponse

// MARK: - Payload Types (wire-compatible)

typealias LinuxBusAlgorithmRunPayload = BotwireBusAlgorithmRunPayload
typealias LinuxBusTimerTickPayload = BotwireBusTimerTickPayload
typealias LinuxBusCapabilities = BotwireBusCapabilities
typealias LinuxBusStateChangePayload = BotwireBusStateChangePayload
typealias LinuxBusHTTPRequestPayload = BotwireBusHTTPRequestPayload
typealias LinuxBusDatabasePayload = BotwireBusDatabasePayload
typealias LinuxBusDeployPayload = BotwireBusDeployPayload
typealias LinuxBusRecallPayload = BotwireBusRecallPayload
typealias LinuxBusFilePayload = BotwireBusFilePayload

// MARK: - Bus Message Handler

extension BotwireRunnerCLI {

    /// Handle an incoming bus message on the Linux runner.
    static func handleBusMessage(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig,
        store: CloudResourceStore,
        tunnel: BotwireRelayTunnelClient
    ) async -> LinuxBusResponse {
        switch message.kind {

        case "algorithmRun":
            return await handleBusAlgorithmRun(message, config: config, store: store)

        case "httpRequest":
            return await handleBusHTTPRequest(message, config: config, store: store, tunnel: tunnel)

        case "stateChange":
            return await handleBusStateChange(message, store: store)

        case "codeBlockExecute":
            return await handleBusCodeBlockExecute(message, config: config, store: store)

        case "timerTick":
            return await handleBusTimerTick(message, config: config, store: store)

        case "dbQuery", "dbMutate":
            return await handleBusDatabaseOp(message, config: config)

        case "deploy":
            return await handleBusDeploy(message, config: config, store: store, tunnel: tunnel)

        case "recall":
            return await handleBusRecall(message, config: config, store: store, tunnel: tunnel)

        case "fileRead", "fileWrite":
            return await handleBusFileOp(message, config: config)

        case "observerEvent", "pauseCheckpoint", "pauseResume":
            // Fire-and-forget / not applicable on Linux runner
            return .ok(for: message)

        default:
            return .error(for: message, "Unsupported bus message kind: \(message.kind)")
        }
    }

    private static func handleBusTimerTick(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig,
        store: CloudResourceStore
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusTimerTickPayload.self, from: message.payload) else {
            return .error(for: message, "Invalid timerTick payload")
        }

        let startupID = message.startupID.uuidString
        let algorithmID = payload.algorithmID.uuidString
        if await !store.isStartupActive(startupID: startupID) {
            return .error(for: message, "Project is paused")
        }
        guard let bundle = try? await store.project(startupID: startupID),
              let algorithm = bundle.algorithms.first(where: { $0.id == algorithmID }),
              let codeBlock = algorithm.codeBlocks.first(where: { $0.role == .logic }) else {
            return .error(for: message, "Algorithm or code block not found")
        }

        let inputJSON = jsonString([
            "tick": payload.tick ?? 0,
            "scheduledAt": ISO8601DateFormatter().string(from: payload.scheduledAt),
            "algorithmID": algorithmID,
            "timerName": payload.timerName ?? algorithm.name,
            "intervalSeconds": payload.intervalSeconds
        ])
        let result = await CloudExecutionResultFactory.executeCodeBlock(
            startupID: startupID,
            algorithmID: algorithmID,
            codeBlock: codeBlock,
            inputJSON: inputJSON,
            workspacePath: config.workspacePath,
            runID: message.id,
            trigger: "timer",
            traceStore: store
        )
        guard let resultData = try? JSONEncoder().encode(result) else {
            return .error(for: message, "Failed to encode execution result")
        }
        return .ok(for: message, payload: resultData)
    }

    // MARK: - Algorithm Run

    private static func handleBusAlgorithmRun(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig,
        store: CloudResourceStore
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusAlgorithmRunPayload.self, from: message.payload) else {
            return .error(for: message, "Invalid algorithmRun payload")
        }

        let startupID = message.startupID.uuidString
        let algorithmID = payload.algorithmID.uuidString

        // Check active state
        if await !store.isStartupActive(startupID: startupID) {
            return .error(for: message, "Project is paused")
        }

        guard let bundle = try? await store.project(startupID: startupID),
              let algorithm = bundle.algorithms.first(where: { $0.id == algorithmID }),
              let codeBlock = algorithm.codeBlocks.first(where: { $0.role == .logic }) else {
            return .error(for: message, "Algorithm or code block not found")
        }

        let result = await CloudExecutionResultFactory.executeCodeBlock(
            startupID: startupID,
            algorithmID: algorithmID,
            codeBlock: codeBlock,
            inputJSON: payload.inputJSON,
            workspacePath: config.workspacePath,
            runID: message.id,
            trigger: payload.trigger,
            traceStore: store
        )

        guard let resultData = try? JSONEncoder().encode(result) else {
            return .error(for: message, "Failed to encode execution result")
        }

        return .ok(for: message, payload: resultData)
    }

    // MARK: - HTTP Request

    private static func handleBusHTTPRequest(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig,
        store: CloudResourceStore,
        tunnel: BotwireRelayTunnelClient
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusHTTPRequestPayload.self, from: message.payload) else {
            return .error(for: message, "Invalid httpRequest payload")
        }

        let startupID = message.startupID.uuidString

        // Check active state
        if await !store.isStartupActive(startupID: startupID) {
            let responsePayload: [String: Any] = [
                "statusCode": 503,
                "headers": ["Content-Type": "application/json"],
                "body": "{\"error\":\"Project paused\"}"
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: responsePayload) else {
                return .error(for: message, "Serialization failed")
            }
            return .ok(for: message, payload: data)
        }

        guard let route = try? await store.routeTarget(path: payload.path),
              let bundle = try? await store.project(startupID: route.startupID),
              let algorithm = bundle.algorithms.first(where: { $0.id == route.algorithmID }),
              let codeBlock = algorithm.codeBlocks.first(where: { $0.role == .logic }) else {
            let responsePayload: [String: Any] = [
                "statusCode": 404,
                "headers": ["Content-Type": "application/json"],
                "body": "{\"error\":\"Route not found\"}"
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: responsePayload) else {
                return .error(for: message, "Serialization failed")
            }
            return .ok(for: message, payload: data)
        }

        let inputDict: [String: Any] = [
            "requestID": message.id,
            "method": payload.method,
            "path": payload.path,
            "headers": payload.headers as Any,
            "query": payload.query as Any,
            "body": payload.body
        ]
        let inputJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: inputDict),
           let str = String(data: data, encoding: .utf8) {
            inputJSON = str
        } else {
            inputJSON = "{}"
        }

        let result = await CloudExecutionResultFactory.executeCodeBlock(
            startupID: route.startupID,
            algorithmID: route.algorithmID,
            codeBlock: codeBlock,
            inputJSON: inputJSON,
            workspacePath: config.workspacePath,
            runID: message.id,
            trigger: "http",
            traceStore: store
        )

        // Extract HTTP response from result
        let statusCode: Int
        let bodyStr: String
        if let httpJSON = result.httpResponseJSON,
           let httpData = httpJSON.data(using: .utf8),
           let httpObj = try? JSONSerialization.jsonObject(with: httpData) as? [String: Any] {
            statusCode = httpObj["statusCode"] as? Int ?? 200
            bodyStr = httpObj["body"] as? String ?? result.outputJSON ?? "{}"
        } else {
            statusCode = result.success ? 200 : 500
            bodyStr = result.outputJSON ?? "{}"
        }

        let responsePayload: [String: Any] = [
            "statusCode": statusCode,
            "headers": ["Content-Type": "application/json"],
            "body": bodyStr
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: responsePayload) else {
            return .error(for: message, "Serialization failed")
        }
        return .ok(for: message, payload: data)
    }

    // MARK: - State Change

    private static func handleBusStateChange(
        _ message: LinuxBusMessage,
        store: CloudResourceStore
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusStateChangePayload.self, from: message.payload) else {
            return .error(for: message, "Invalid stateChange payload")
        }

        await store.setStartupActive(
            startupID: payload.startupID.uuidString,
            isActive: payload.isActive
        )

        return .ok(for: message)
    }

    // MARK: - Code Block Execute

    private static func handleBusCodeBlockExecute(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig,
        store: CloudResourceStore
    ) async -> LinuxBusResponse {
        // Reuse the existing BREPExecuteRequest format
        guard let request = try? JSONDecoder().decode(BREPExecuteRequest.self, from: message.payload) else {
            return .error(for: message, "Invalid codeBlockExecute payload")
        }

        guard let stored = try? await store.codeBlock(id: request.codeBlockID) else {
            return .error(for: message, "Code block not found on cloud runner")
        }

        let result = await CloudExecutionResultFactory.execute(stored: stored, request: request, traceStore: store)
        guard let resultData = try? JSONEncoder().encode(result) else {
            return .error(for: message, "Failed to encode result")
        }

        return .ok(for: message, payload: resultData)
    }

    // MARK: - Database Operations

    private static func handleBusDatabaseOp(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusDatabasePayload.self, from: message.payload) else {
            return .error(for: message, "Invalid database payload")
        }

        let workspace = config.workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace"
        let dbPath = URL(fileURLWithPath: workspace)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(message.startupID.uuidString, isDirectory: true)
            .appendingPathComponent("databases", isDirectory: true)
            .appendingPathComponent(payload.databaseID.uuidString, isDirectory: true)

        let store = OxiDBEmbeddedStore(root: dbPath)
        do {
            _ = try store.open()
        } catch {
            return .error(for: message, "Failed to open database: \(error.localizedDescription)")
        }
        defer { store.close() }

        // Parse the payload JSON into a command
        guard let payloadData = payload.payloadJSON.data(using: .utf8),
              let payloadObj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return .error(for: message, "Invalid payload JSON")
        }

        // Build the OxiDB command from the operation + payload
        let command = buildCommand(operation: payload.operation, payload: payloadObj)
        guard let command else {
            return .error(for: message, "Unknown database operation: \(payload.operation)")
        }

        do {
            let result = try store.execute(command: command)
            if message.kind == "dbMutate",
               let mutationEvent = databaseMutationEvent(
                message: message,
                payload: payload,
                command: command,
                result: result
               ) {
                let workspacePath = config.workspacePath
                Task {
                    await LinuxDataWatchRunner.handle(event: mutationEvent, workspacePath: workspacePath)
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: result) else {
                return .error(for: message, "Failed to encode database result")
            }
            return .ok(for: message, payload: data)
        } catch {
            return .error(for: message, "Database error: \(error.localizedDescription)")
        }
    }

    private static func databaseMutationEvent(
        message: LinuxBusMessage,
        payload: LinuxBusDatabasePayload,
        command: [String: Any],
        result: [String: Any]
    ) -> BotwireDatabaseMutationEvent? {
        guard let rawOperation = command["cmd"] as? String,
              let operation = normalizedDatabaseMutationOperation(rawOperation),
              let collection = command["collection"] as? String,
              !collection.isEmpty else {
            return nil
        }
        return BotwireDatabaseMutationEvent(
            projectID: message.startupID.uuidString,
            databaseID: payload.databaseID.uuidString,
            databaseName: payload.databaseName,
            collection: collection,
            operation: operation,
            rawOperation: rawOperation,
            documentIDs: databaseMutationDocumentIDs(command: command, result: result),
            touchedPropertyPaths: databaseMutationTouchedPropertyPaths(command: command),
            sourceAlgorithmID: nil,
            sourceCodeBlockID: nil
        )
    }

    private static func normalizedDatabaseMutationOperation(_ command: String) -> String? {
        switch command {
        case "insert", "insert_many":
            return "insert"
        case "update", "update_one":
            return "update"
        case "delete", "delete_one", "delete_many":
            return "delete"
        default:
            return nil
        }
    }

    private static func databaseMutationDocumentIDs(command: [String: Any], result: [String: Any]) -> [String] {
        if let data = result["data"] as? [String: Any],
           let id = data["id"] {
            return [String(describing: id)]
        }
        if let ids = result["data"] as? [Any] {
            return ids.map { String(describing: $0) }
        }
        if let query = command["query"] as? [String: Any],
           let id = query["_id"] {
            return [String(describing: id)]
        }
        return []
    }

    private static func databaseMutationTouchedPropertyPaths(command: [String: Any]) -> [String] {
        guard let update = command["update"] as? [String: Any] else { return [] }
        var result = Set<String>()
        for payload in update.values {
            if let fields = payload as? [String: Any] {
                for key in fields.keys { result.insert(key) }
            }
        }
        return result.sorted()
    }

    private static func buildCommand(operation: String, payload: [String: Any]) -> [String: Any]? {
        let collection = payload["collection"] as? String ?? ""
        switch operation {
        case "listCollections":
            return ["cmd": "list_collections"]
        case "createCollection":
            return ["cmd": "create_collection", "collection": collection]
        case "insertOne":
            guard let doc = payload["document"] as? [String: Any] else { return nil }
            return ["cmd": "insert", "collection": collection, "doc": doc]
        case "insertMany":
            guard let docs = payload["documents"] as? [[String: Any]] else { return nil }
            return ["cmd": "insert_many", "collection": collection, "docs": docs]
        case "find":
            var cmd: [String: Any] = ["cmd": "find", "collection": collection, "query": payload["query"] as? [String: Any] ?? [:]]
            if let sort = payload["sort"] as? [String: Any] { cmd["sort"] = sort }
            if let skip = payload["skip"] as? Int { cmd["skip"] = skip }
            if let limit = payload["limit"] as? Int { cmd["limit"] = limit }
            return cmd
        case "findOne":
            return ["cmd": "find_one", "collection": collection, "query": payload["query"] as? [String: Any] ?? [:]]
        case "updateOne":
            guard let update = payload["update"] as? [String: Any] else { return nil }
            return ["cmd": "update_one", "collection": collection, "query": payload["query"] as? [String: Any] ?? [:], "update": update]
        case "deleteOne":
            return ["cmd": "delete_one", "collection": collection, "query": payload["query"] as? [String: Any] ?? [:]]
        case "count":
            return ["cmd": "count", "collection": collection, "query": payload["query"] as? [String: Any] ?? [:]]
        default:
            return nil
        }
    }

    // MARK: - Deploy (receive a startup via bus)

    private static func handleBusDeploy(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig,
        store: CloudResourceStore,
        tunnel: BotwireRelayTunnelClient
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusDeployPayload.self, from: message.payload) else {
            return .error(for: message, "Invalid deploy payload")
        }

        guard let transferData = payload.transferPayloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: transferData) as? [String: Any] else {
            return .error(for: message, "Invalid transfer payload encoding")
        }

        guard let senderPeerID = object["senderPeerID"] as? String,
              let senderEndpoint = object["senderEndpoint"] as? String,
              let startupSnap = object["startupSnapshot"] as? [String: Any],
              let startupID = startupSnap["id"] as? String,
              let startupName = startupSnap["name"] as? String,
              let startupDescription = startupSnap["description"] as? String,
              let algorithms = startupSnap["algorithms"] as? [[String: Any]] else {
            return .error(for: message, "Invalid startup transfer format")
        }

        do {
            var bundleAlgorithms: [BotwireAlgorithm] = []
            var metadata: [String: String] = [:]
            storeLinuxStartupSnapshotMetadata(from: startupSnap, into: &metadata)
            let routePaths = object["publicRoutePaths"] as? [String: String] ?? [:]

            for algoSnap in algorithms {
                guard let algoID = algoSnap["id"] as? String,
                      let algoName = algoSnap["name"] as? String,
                      let algoDescription = algoSnap["description"] as? String,
                      let codeblocks = algoSnap["codeblocks"] as? [[String: Any]] else { continue }

                bundleAlgorithms.append(
                    BotwireAlgorithm(
                        id: algoID,
                        name: algoName,
                        codeBlocks: codeblocks.compactMap(Self.portableCodeBlock(from:))
                    )
                )
                metadata["algorithm.\(algoID).description"] = algoDescription
                metadata["algorithm.\(algoID).entryPoint"] = (algoSnap["entryPointRawValue"] as? String) ?? "manual"
                metadata["algorithm.\(algoID).httpConfig"] = jsonString(algoSnap["httpConfig"] as? [String: Any] ?? [:])
                storeTimerMetadata(from: algoSnap, algorithmID: algoID, into: &metadata)
                LinuxDataWatchRunner.storeDataWatchMetadata(from: algoSnap, algorithmID: algoID, into: &metadata)
                try? await store.registerRoute(path: routePaths[algoID], startupID: startupID, algorithmID: algoID)

                for block in codeblocks {
                    guard let cbID = block["id"] as? String,
                          let cbName = block["name"] as? String,
                          let cbAction = block["action"] as? String,
                          let cbRole = block["role"] as? String,
                          let codeData = block["codeData"] as? [String: Any],
                          let cbLanguage = codeData["language"] as? String,
                          let cbCode = codeData["code"] as? String else { continue }

                    let desc = BREPCodeBlockDescriptor(
                        id: cbID, name: cbName, action: cbAction,
                        role: cbRole, language: cbLanguage, code: cbCode
                    )
                    let cbPayload = BREPCodeBlockTransferPayload(
                        startupID: startupID, startupName: startupName,
                        startupDescription: startupDescription, algorithmID: algoID,
                        algorithmName: algoName, algorithmDescription: algoDescription,
                        codeBlock: desc, senderPeerID: senderPeerID, senderEndpoint: senderEndpoint
                    )
                    try await store.store(cbPayload)
                }
            }

            let bundle = BotwireProjectBundle(
                id: startupID, name: startupName, description: startupDescription,
                algorithms: bundleAlgorithms, metadata: metadata
            )
            try await store.storeProject(bundle)
            await store.writeDatabases(object["databases"] as? [[String: Any]] ?? [], startupID: startupID)
            await store.writeFiles(object["files"] as? [[String: Any]] ?? [], startupID: startupID)
            await store.storeSenderInfo(startupID: startupID, peerID: senderPeerID, endpoint: senderEndpoint)

            // Re-register relay routes
            if let routes = try? await store.relayRoutes() {
                try? await tunnel.registerRoutes(routes)
            }

            // Sync settings (agent profiles, LLM configs, etc.)
            await syncSettings(from: object, config: config)

            // Sync initial active state from the snapshot
            if let isActive = startupSnap["isActive"] as? Bool {
                await store.setStartupActive(startupID: startupID, isActive: isActive)
            }

            // Register resource proxy handler
            registerResourceProxy(
                startupID: startupID,
                senderPeerID: senderPeerID,
                tunnel: tunnel
            )

            emitCloudEvent("startup.received.bus", [
                "runnerID": config.runnerID,
                "startupID": startupID,
                "startupName": startupName,
                "senderPeerID": senderPeerID
            ])

            let resultJSON: [String: String] = ["startupID": startupID]
            guard let resultData = try? JSONEncoder().encode(resultJSON) else {
                return .ok(for: message)
            }
            return .ok(for: message, payload: resultData)
        } catch {
            return .error(for: message, "Deploy failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Recall (remove a deployed startup via bus)

    private static func handleBusRecall(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig,
        store: CloudResourceStore,
        tunnel: BotwireRelayTunnelClient
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusRecallPayload.self, from: message.payload) else {
            return .error(for: message, "Invalid recall payload")
        }

        let startupID = payload.startupID.uuidString

        do {
            try await store.removeStartup(startupID: startupID)
            ResourceProxyRegistry.shared.unregister(projectId: startupID)

            // Re-register relay routes (removed startup's routes are now gone)
            if let routes = try? await store.relayRoutes() {
                try? await tunnel.registerRoutes(routes)
            }

            emitCloudEvent("startup.recalled.bus", [
                "runnerID": config.runnerID,
                "startupID": startupID
            ])

            return .ok(for: message)
        } catch {
            return .error(for: message, "Recall failed: \(error.localizedDescription)")
        }
    }

    // MARK: - File Operations

    private static func handleBusFileOp(
        _ message: LinuxBusMessage,
        config: BotwireRunnerConfig
    ) async -> LinuxBusResponse {
        guard let payload = try? JSONDecoder().decode(LinuxBusFilePayload.self, from: message.payload) else {
            return .error(for: message, "Invalid file payload")
        }

        let startupIDStr = payload.startupID.uuidString
        guard let proxyHandler = ResourceProxyRegistry.shared.handler(for: startupIDStr) else {
            print("🚌 [LinuxBus] File operation '\(payload.operation)' failed: No proxy handler for startup '\(startupIDStr)'")
            return .error(for: message, "No resource proxy handler registered for startup '\(startupIDStr)'")
        }

        var proxyReq: [String: Any] = [
            "resourceType": "file",
            "startupID": startupIDStr,
            "operation": payload.operation
        ]

        if let fileID = payload.fileID { proxyReq["fileID"] = fileID }
        if let name = payload.name { proxyReq["relativePath"] = name }
        if let data = payload.data { proxyReq["content"] = data }
        if let mimeType = payload.mimeType { proxyReq["mimeType"] = mimeType }
        
        // Use base64 encoding to preserve binary data exactly as expected over proxy
        proxyReq["encoding"] = "base64"

        let filesRoot: URL
        if let wp = config.workspacePath {
            filesRoot = URL(fileURLWithPath: wp)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(startupIDStr, isDirectory: true)
                .appendingPathComponent("ProjectFiles", isDirectory: true)
        } else {
            filesRoot = URL(fileURLWithPath: "/tmp/botwire_projects/\(startupIDStr)/ProjectFiles")
        }

        var localURL: URL? = nil
        var hashURL: URL? = nil

        // Add caching ETag if we already have the file locally
        if payload.operation == "read", let relativePath = payload.name, !relativePath.isEmpty {
            let fileURL = filesRoot.appendingPathComponent(relativePath, isDirectory: false)
            localURL = fileURL
            hashURL = fileURL.appendingPathExtension("bwhash")

            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let hURL = hashURL, let cachedHash = try? String(contentsOf: hURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                    proxyReq["ifNoneMatch"] = cachedHash
                }
            }
        }

        guard let responseStr = proxyHandler(proxyReq),
              let responseData = responseStr.data(using: .utf8) else {
            print("🚌 [LinuxBus] File operation '\(payload.operation)' proxy request failed")
            return .error(for: message, "Proxy request failed or source device unreachable")
        }

        // Process response for caching if it's a read operation
        if payload.operation == "read", let localURL = localURL,
           let responseObj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let success = responseObj["success"] as? Bool, success {
            
            if let unchanged = responseObj["unchanged"] as? Bool, unchanged {
                // File hasn't changed on source. Read from local cache and inject content to fulfill the bus message.
                if let fileData = try? Data(contentsOf: localURL) {
                    var modifiedResponse = responseObj
                    modifiedResponse["content"] = fileData.base64EncodedString()
                    modifiedResponse["encoding"] = "base64"
                    modifiedResponse["unchanged"] = nil // hide caching detail from the bus caller
                    if let finalData = try? JSONSerialization.data(withJSONObject: modifiedResponse) {
                        return .ok(for: message, payload: finalData)
                    }
                }
            } else if let contentStr = responseObj["content"] as? String, let enc = responseObj["encoding"] as? String {
                // New file content received from source. Save it to local cache.
                try? FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if enc == "base64", let newBytes = Data(base64Encoded: contentStr) {
                    try? newBytes.write(to: localURL)
                } else if enc == "utf8" || enc == "text", let newBytes = contentStr.data(using: .utf8) {
                    try? newBytes.write(to: localURL)
                }
                if let hURL = hashURL, let newHash = responseObj["hash"] as? String {
                    try? newHash.data(using: .utf8)?.write(to: hURL)
                }
            }
        }

        // Forward the proxy response directly back over the bus
        return .ok(for: message, payload: responseData)
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
