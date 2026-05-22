#if os(Linux) && canImport(CJavaScriptCoreGTK)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import BotwirePersistence
import BotwireCore

// A thread-safe queue for JS responses
final class JSResponseQueue: @unchecked Sendable {
    private var queue: [JSHostResponse] = []
    private let lock = NSLock()
    
    func push(_ response: JSHostResponse) {
        lock.lock()
        queue.append(response)
        lock.unlock()
    }
    
    func popAll() -> [JSHostResponse] {
        lock.lock()
        let all = queue
        queue.removeAll(keepingCapacity: true)
        lock.unlock()
        return all
    }
}

struct JSHostRequest: Codable {
    let id: String
    let command: String
    let args: String // JSON string
}

struct JSHostResponse {
    let id: String
    let success: Bool
    let payload: String // JSON string
}

final class LinuxJSHostBridge: Sendable {
    private let responseQueue = JSResponseQueue()
    private let projectId: String
    private let algorithmId: String?
    private let codeBlockId: String?
    private let workspacePath: String?
    private let databaseMutationHandler: (@Sendable (BotwireDatabaseMutationEvent) -> Void)?
    private var browserEngine: LinuxBrowserAutomationEngine?

    /// Optional callback to proxy resource requests to the source device.
    /// Takes a JSON dict `[String: Any]` describing the request, returns a JSON string response.
    /// Set by the runner when a deployment has a known sender peer.
    nonisolated(unsafe) var resourceProxyHandler: (([String: Any]) -> String?)?
    
    init(
        projectId: String,
        algorithmId: String? = nil,
        codeBlockId: String? = nil,
        workspacePath: String? = nil,
        databaseMutationHandler: (@Sendable (BotwireDatabaseMutationEvent) -> Void)? = nil
    ) {
        self.projectId = projectId
        self.algorithmId = algorithmId
        self.codeBlockId = codeBlockId
        self.workspacePath = workspacePath
        self.databaseMutationHandler = databaseMutationHandler
    }
    
    /// Shut down any browser engine that was started during execution.
    func shutdownBrowser() {
        browserEngine?.shutdown()
        browserEngine = nil
    }
    
    func handleRequests(_ requestsJSON: String) {
        guard let data = requestsJSON.data(using: .utf8) else {
            print("Bridge Error: Could not convert requests to data")
            return
        }
        do {
            let requests = try JSONDecoder().decode([JSHostRequest].self, from: data)
            for req in requests {
                handleRequest(req)
            }
        } catch {
            print("Bridge Error: Failed to decode JSHostRequest array: \(error)")
        }
    }
    
    func popResponses() -> [JSHostResponse] {
        return responseQueue.popAll()
    }
    
    private func handleRequest(_ req: JSHostRequest) {
        switch req.command {
        case "fetch":
            handleFetch(req)
        case "setTimeout":
            handleSetTimeout(req)
        case "db":
            handleDb(req)
        case "files":
            handleFiles(req)
        case "config.getLLMProfiles":
            handleGetLLMProfiles(req)
        case "config.getAgentProfiles", "config.getAgents":
            handleGetAgentProfiles(req)
        case "config.getSkills":
            handleGetSkills(req)
        case "config.getContexts":
            handleGetContexts(req)
        case "config.evalScriptedContext":
            handleEvalScriptedContext(req)
        case "tools.list":
            handleToolsList(req)
        case "tools.run":
            handleToolsRun(req)
        case "browser":
            handleBrowser(req)
        default:
            responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral("Unknown command: \(req.command)")))
        }
    }
    
    private func handleSetTimeout(_ req: JSHostRequest) {
        let delayMs = Int(req.args) ?? 0
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: "null"))
        }
    }
    
    private func handleDb(_ req: JSHostRequest) {
        guard let data = req.args.data(using: .utf8),
              let queryObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Invalid db arguments\""))
            return
        }
        emitBridgeEvent("db.started", [
            "projectID": projectId,
            "requestID": req.id
        ])
        
        Task {
            let startedAt = Date()
            do {
                let dbPath: URL
                if let workspacePath = self.workspacePath {
                    dbPath = URL(fileURLWithPath: workspacePath)
                        .appendingPathComponent("projects", isDirectory: true)
                        .appendingPathComponent(self.projectId, isDirectory: true)
                        .appendingPathComponent("data.oxidb")
                } else {
                    dbPath = URL(fileURLWithPath: "/tmp/botwire_projects/\(self.projectId)/data.oxidb")
                }

                // Check if local database exists; if not, try proxying to source device
                let localExists = FileManager.default.fileExists(atPath: dbPath.path)

                let proxyHandler = self.resourceProxyHandler ?? ResourceProxyRegistry.shared.handler(for: self.projectId)
                if !localExists, let proxyHandler {
                    // ── Proxy to source device ──
                    print("🔀 [DB Proxy] Local DB not found at \(dbPath.path), proxying to source device")
                    var proxyRequest: [String: Any] = [
                        "resourceType": "database",
                        "startupID": self.projectId,
                        "command": queryObj
                    ]
                    if let algorithmId = self.algorithmId {
                        proxyRequest["sourceAlgorithmID"] = algorithmId
                    }
                    if let codeBlockId = self.codeBlockId {
                        proxyRequest["sourceCodeBlockID"] = codeBlockId
                    }
                    if let dbName = queryObj["database"] as? String ?? queryObj["databaseName"] as? String {
                        proxyRequest["databaseName"] = dbName
                    }
                    
                    if let responseStr = proxyHandler(proxyRequest),
                       let responseData = responseStr.data(using: .utf8),
                       let responseObj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                        if let success = responseObj["success"] as? Bool, success,
                           let result = responseObj["result"] as? [String: Any] {
                            if let resData = try? JSONSerialization.data(withJSONObject: result),
                               let resString = String(data: resData, encoding: .utf8) {
                                self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: resString))
                                self.emitBridgeEvent("db.finished", [
                                    "projectID": self.projectId,
                                    "requestID": req.id,
                                    "success": true,
                                    "proxied": true,
                                    "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                                ])
                                return
                            }
                        }
                        let errorMsg = responseObj["error"] as? String ?? "Proxy returned unexpected response"
                        self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(errorMsg)))
                        self.emitBridgeEvent("db.finished", [
                            "projectID": self.projectId,
                            "requestID": req.id,
                            "success": false,
                            "proxied": true,
                            "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                            "error": errorMsg
                        ])
                        return
                    } else {
                        print("🔀 [DB Proxy] Proxy handler returned nil — source device may be offline")
                        self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Database not found locally and source device is unreachable\""))
                        self.emitBridgeEvent("db.finished", [
                            "projectID": self.projectId,
                            "requestID": req.id,
                            "success": false,
                            "proxied": true,
                            "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                            "error": "Source device unreachable"
                        ])
                        return
                    }
                }

                // ── Execute locally ──
                let store = BotwirePersistence.OxiDBEmbeddedStore(root: dbPath)
                let result = try store.execute(command: queryObj)
                self.emitDatabaseMutationIfNeeded(command: queryObj, result: result)
                
                if let resData = try? JSONSerialization.data(withJSONObject: result),
                   let resString = String(data: resData, encoding: .utf8) {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: resString))
                    self.emitBridgeEvent("db.finished", [
                        "projectID": self.projectId,
                        "requestID": req.id,
                        "success": true,
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                    ])
                } else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode db result\""))
                    self.emitBridgeEvent("db.finished", [
                        "projectID": self.projectId,
                        "requestID": req.id,
                        "success": false,
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                    ])
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
                self.emitBridgeEvent("db.finished", [
                    "projectID": self.projectId,
                    "requestID": req.id,
                    "success": false,
                    "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func emitDatabaseMutationIfNeeded(command: [String: Any], result: [String: Any]) {
        guard let handler = databaseMutationHandler,
              let rawCommand = command["cmd"] as? String,
              let operation = Self.normalizedMutationOperation(rawCommand),
              let collection = command["collection"] as? String,
              !collection.isEmpty else {
            return
        }

        handler(
            BotwireDatabaseMutationEvent(
                projectID: projectId,
                databaseID: nil,
                databaseName: command["database"] as? String ?? command["databaseName"] as? String,
                collection: collection,
                operation: operation,
                rawOperation: rawCommand,
                documentIDs: Self.documentIDs(command: command, result: result),
                touchedPropertyPaths: Self.touchedPropertyPaths(command: command),
                sourceAlgorithmID: algorithmId,
                sourceCodeBlockID: codeBlockId
            )
        )
    }

    private static func normalizedMutationOperation(_ command: String) -> String? {
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

    private static func documentIDs(command: [String: Any], result: [String: Any]) -> [String] {
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

    private static func touchedPropertyPaths(command: [String: Any]) -> [String] {
        guard let update = command["update"] as? [String: Any] else { return [] }
        var result = Set<String>()
        for payload in update.values {
            if let fields = payload as? [String: Any] {
                for key in fields.keys { result.insert(key) }
            }
        }
        return result.sorted()
    }

    // MARK: - File handler (local-first, proxy fallback)

    private func handleFiles(_ req: JSHostRequest) {
        guard let data = req.args.data(using: .utf8),
              let argsObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Invalid files arguments\""))
            return
        }
        let operation   = argsObj["operation"]     as? String ?? "read"
        let relativePath = argsObj["relativePath"] as? String ?? argsObj["path"] as? String ?? ""
        let encoding    = (argsObj["encoding"]     as? String ?? "base64").lowercased()

        emitBridgeEvent("files.started", [
            "projectID": projectId, "requestID": req.id, "operation": operation, "path": relativePath
        ])

        Task {
            let startedAt = Date()

            // Local ProjectFiles root written by writeFiles() at deploy time
            let filesRoot: URL
            if let wp = self.workspacePath {
                filesRoot = URL(fileURLWithPath: wp)
                    .appendingPathComponent("projects", isDirectory: true)
                    .appendingPathComponent(self.projectId, isDirectory: true)
                    .appendingPathComponent("ProjectFiles", isDirectory: true)
            } else {
                filesRoot = URL(fileURLWithPath: "/tmp/botwire_projects/\(self.projectId)/ProjectFiles")
            }

            if operation == "list" {
                if let entries = try? FileManager.default.contentsOfDirectory(
                    at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) {
                    let items: [[String: Any]] = entries.map { url in
                        let rel = url.path.replacingOccurrences(of: filesRoot.path + "/", with: "")
                        return ["relativePath": rel, "name": url.lastPathComponent]
                    }
                    let result: [String: Any] = ["success": true, "files": items]
                    if let rd = try? JSONSerialization.data(withJSONObject: result),
                       let rs = String(data: rd, encoding: .utf8) {
                        self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: rs))
                        self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": true, "proxied": false, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
                        return
                    }
                }
                // Proxy fallback for list
                let proxyHandler = self.resourceProxyHandler ?? ResourceProxyRegistry.shared.handler(for: self.projectId)
                if let proxyHandler {
                    let proxyReq: [String: Any] = ["resourceType": "file", "startupID": self.projectId, "operation": "list"]
                    if let resp = proxyHandler(proxyReq), let rd = resp.data(using: .utf8),
                       let ro = try? JSONSerialization.jsonObject(with: rd) as? [String: Any],
                       let rs = String(data: (try? JSONSerialization.data(withJSONObject: ro)) ?? Data(), encoding: .utf8) {
                        self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: rs))
                        self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": true, "proxied": true, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
                        return
                    }
                }
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"File list unavailable\""))
                return
            }

            // ── read ──
            guard !relativePath.isEmpty else {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"relativePath or path required\""))
                return
            }
            let localURL = filesRoot.appendingPathComponent(relativePath, isDirectory: false)
            let hashURL = localURL.appendingPathExtension("bwhash")
            let localExists = FileManager.default.fileExists(atPath: localURL.path)
            
            // Try to read local hash if available
            var cachedHash: String? = nil
            if localExists {
                cachedHash = try? String(contentsOf: hashURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // ── Proxy fallback (or hash validation) ──
            let proxyHandler = self.resourceProxyHandler ?? ResourceProxyRegistry.shared.handler(for: self.projectId)
            
            // If we have no proxy, serve local directly if it exists
            if proxyHandler == nil {
                if localExists, let fileData = try? Data(contentsOf: localURL) {
                    let content: String = (encoding == "utf8" || encoding == "text")
                        ? (String(data: fileData, encoding: .utf8) ?? fileData.base64EncodedString())
                        : fileData.base64EncodedString()
                    let result: [String: Any] = ["success": true, "content": content, "encoding": encoding, "file": ["relativePath": relativePath]]
                    if let rd = try? JSONSerialization.data(withJSONObject: result), let rs = String(data: rd, encoding: .utf8) {
                        self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: rs))
                        self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": true, "proxied": false, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
                        return
                    }
                }
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"File not found: \(relativePath)\""))
                self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": false, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000), "error": "File not found"])
                return
            }

            // We have a proxy handler: validate or fetch
            print("🔀 [File Proxy] checking '\(relativePath)' via source" + (cachedHash != nil ? " [ETag: \(cachedHash!.prefix(6))]" : ""))
            var proxyReq: [String: Any] = ["resourceType": "file", "startupID": self.projectId, "operation": "read", "relativePath": relativePath, "encoding": encoding]
            if let cachedHash { proxyReq["ifNoneMatch"] = cachedHash }
            
            if let proxyHandler, let resp = proxyHandler(proxyReq), let rd = resp.data(using: .utf8),
               let ro = try? JSONSerialization.jsonObject(with: rd) as? [String: Any] {
                
                if let success = ro["success"] as? Bool, success {
                    // Check if unchanged
                    if let unchanged = ro["unchanged"] as? Bool, unchanged, localExists, let fileData = try? Data(contentsOf: localURL) {
                        print("🔄 [File Proxy] '\(relativePath)' unchanged, using local cache")
                        let content: String = (encoding == "utf8" || encoding == "text")
                            ? (String(data: fileData, encoding: .utf8) ?? fileData.base64EncodedString())
                            : fileData.base64EncodedString()
                        let result: [String: Any] = ["success": true, "content": content, "encoding": encoding, "file": ["relativePath": relativePath]]
                        if let rd = try? JSONSerialization.data(withJSONObject: result), let rs = String(data: rd, encoding: .utf8) {
                            self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: rs))
                            self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": true, "proxied": true, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
                            return
                        }
                    }
                    
                    // New data received, persist it to cache
                    if let contentStr = ro["content"] as? String, let enc = ro["encoding"] as? String {
                        try? FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if enc == "base64", let newBytes = Data(base64Encoded: contentStr) {
                            try? newBytes.write(to: localURL)
                        } else if enc == "utf8" || enc == "text", let newBytes = contentStr.data(using: .utf8) {
                            try? newBytes.write(to: localURL)
                        }
                        if let newHash = ro["hash"] as? String {
                            try? newHash.data(using: .utf8)?.write(to: hashURL)
                        }
                    }

                    if let rs = String(data: (try? JSONSerialization.data(withJSONObject: ro)) ?? Data(), encoding: .utf8) {
                        self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: rs))
                        self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": true, "proxied": true, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
                        return
                    }
                } else {
                    let errMsg = ro["error"] as? String ?? "Proxy returned unexpected response"
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(errMsg)))
                    self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": false, "proxied": true, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000), "error": errMsg])
                    return
                }
            }
            
            // Proxy failed and no local copy
            self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"File not found locally and source device is unreachable\""))
            self.emitBridgeEvent("files.finished", ["projectID": self.projectId, "requestID": req.id, "success": false, "proxied": true, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000), "error": "Source device unreachable"])
        }
    }

    private func handleFetch(_ req: JSHostRequest) {

        struct FetchArgs: Codable {
            let url: String
            let method: String?
            let headers: [String: String]?
            let body: String?
        }
        
        guard let data = req.args.data(using: .utf8),
              let args = try? JSONDecoder().decode(FetchArgs.self, from: data),
              let url = URL(string: args.url) else {
            responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Invalid fetch arguments\""))
            return
        }
        emitBridgeEvent("fetch.started", [
            "projectID": projectId,
            "requestID": req.id,
            "url": args.url,
            "method": args.method ?? "GET"
        ])
        
        var request = URLRequest(url: url)
        request.httpMethod = args.method ?? "GET"
        if let headers = args.headers {
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let body = args.body {
            request.httpBody = body.data(using: .utf8)
        }
        
        Task {
            let startedAt = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                let headers = http?.allHeaderFields as? [String: String] ?? [:]
                let bodyString = String(data: data, encoding: .utf8) ?? ""
                
                struct FetchResult: Codable {
                    let status: Int
                    let headers: [String: String]
                    let body: String
                }
                
                let result = FetchResult(status: status, headers: headers, body: bodyString)
                if let resData = try? JSONEncoder().encode(result),
                   let resString = String(data: resData, encoding: .utf8) {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: resString))
                    self.emitBridgeEvent("fetch.finished", [
                        "projectID": self.projectId,
                        "requestID": req.id,
                        "url": args.url,
                        "method": args.method ?? "GET",
                        "status": status,
                        "responseBytes": data.count,
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                    ])
                } else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode fetch result\""))
                    self.emitBridgeEvent("fetch.finished", [
                        "projectID": self.projectId,
                        "requestID": req.id,
                        "url": args.url,
                        "method": args.method ?? "GET",
                        "success": false,
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                    ])
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
                self.emitBridgeEvent("fetch.finished", [
                    "projectID": self.projectId,
                    "requestID": req.id,
                    "url": args.url,
                    "method": args.method ?? "GET",
                    "success": false,
                    "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func handleGetLLMProfiles(_ req: JSHostRequest) {
        Task {
            do {
                guard let workspacePath = self.workspacePath else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"No workspace path configured\""))
                    return
                }
                
                let dbPath = URL(fileURLWithPath: workspacePath).appendingPathComponent("appdata.oxidb")
                let store = BotwirePersistence.NativeOxiModelStore(root: dbPath)
                let profiles = try await store.fetch(BotwirePersistence.StoredLLMProfile.self)
                
                let items: [[String: Any]] = profiles.map { profile in
                    var entry: [String: Any] = [
                        "id": profile.id,
                        "name": profile.name,
                        "baseURL": profile.sanitizedBaseURL,
                        "apiKey": profile.apiKey,
                        "model": profile.model
                    ]
                    if let proxy = profile.sanitizedProxyPath {
                        entry["proxyPath"] = proxy
                    }
                    entry["features"] = profile.featureSupport.normalizedTags.map(\.rawValue)
                    return entry
                }

                let data = try JSONSerialization.data(withJSONObject: items, options: [])
                if let payload = String(data: data, encoding: .utf8) {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: payload))
                } else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode profiles string\""))
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
            }
        }
    }

    private func handleGetAgentProfiles(_ req: JSHostRequest) {
        Task {
            do {
                guard let workspacePath = self.workspacePath else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"No workspace path configured\""))
                    return
                }
                
                let dbPath = URL(fileURLWithPath: workspacePath).appendingPathComponent("appdata.oxidb")
                let store = BotwirePersistence.NativeOxiModelStore(root: dbPath)
                let profiles = try await store.fetch(BotwirePersistence.StoredAgentProfile.self)
                
                let items: [[String: Any]] = profiles.map { profile in
                    var contexts: [String] = []
                    if let cData = profile.contextsJSON?.data(using: .utf8),
                       let cArray = try? JSONSerialization.jsonObject(with: cData) as? [String] {
                        contexts = cArray
                    }
                    return [
                        "id": profile.id,
                        "name": profile.name,
                        "systemPrompt": profile.systemPrompt,
                        "apiProfileID": profile.apiProfileID ?? "",
                        "model": "unknown", // Resolves via LLM API Profile in real app
                        "contexts": contexts
                    ]
                }

                let data = try JSONSerialization.data(withJSONObject: items, options: [])
                if let payload = String(data: data, encoding: .utf8) {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: payload))
                } else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode agent profiles string\""))
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
            }
        }
    }

    private func handleGetSkills(_ req: JSHostRequest) {
        Task {
            do {
                guard let workspacePath = self.workspacePath else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"No workspace path configured\""))
                    return
                }
                
                let dbPath = URL(fileURLWithPath: workspacePath).appendingPathComponent("appdata.oxidb")
                let store = BotwirePersistence.NativeOxiModelStore(root: dbPath)
                let skills = try await store.fetch(BotwirePersistence.StoredSkill.self)
                
                let encoder = JSONEncoder()
                let data = try encoder.encode(skills)
                if let payload = String(data: data, encoding: .utf8) {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: payload))
                } else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode skills string\""))
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
            }
        }
    }

    private func handleGetContexts(_ req: JSHostRequest) {
        Task {
            do {
                guard let workspacePath = self.workspacePath else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"No workspace path configured\""))
                    return
                }
                
                let dbPath = URL(fileURLWithPath: workspacePath).appendingPathComponent("appdata.oxidb")
                let store = BotwirePersistence.NativeOxiModelStore(root: dbPath)
                let contexts = try await store.fetch(BotwirePersistence.StoredContextDefinition.self)
                
                let encoder = JSONEncoder()
                let data = try encoder.encode(contexts)
                if let payload = String(data: data, encoding: .utf8) {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: payload))
                } else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode contexts string\""))
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
            }
        }
    }

    private func handleEvalScriptedContext(_ req: JSHostRequest) {
        guard let data = req.args.data(using: .utf8),
              let argsObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = argsObj["key"] as? String else {
            responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Invalid evaluate context arguments\""))
            return
        }

        Task {
            do {
                guard let workspacePath = self.workspacePath else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"No workspace path configured\""))
                    return
                }

                let dbPath = URL(fileURLWithPath: workspacePath).appendingPathComponent("appdata.oxidb")
                let store = BotwirePersistence.NativeOxiModelStore(root: dbPath)
                let contexts = try await store.fetch(BotwirePersistence.StoredContextDefinition.self)

                guard let definition = contexts.first(where: { $0.id == key }) else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral("Context not found: \(key)")))
                    return
                }

                guard definition.executionModeRawValue == "scripted" else {
                    let enc = JSONEncoder()
                    if let resData = try? enc.encode(definition.content),
                       let resString = String(data: resData, encoding: .utf8) {
                        self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: resString))
                    } else {
                        self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode context\""))
                    }
                    return
                }

                let script = definition.scriptSource ?? ""
                let wrappedScript = """
                async function main() {
                  const __ctx = {};
                  const __clone = (value) => {
                    try { return JSON.parse(JSON.stringify(value === undefined ? null : value)); }
                    catch (_) { return value === undefined ? null : value; }
                  };
                  const contextAPI = {
                    getStartupProfile: async () => __clone(__ctx.startupProfile || {}),
                    getStartupNotes: async () => __clone(__ctx.startupNotes || []),
                    getStartupTodos: async () => __clone(__ctx.startupTodos || []),
                    getAlgorithmsOverview: async () => __clone(__ctx.algorithmsOverview || []),
                    getDatabaseOverview: async () => __clone(__ctx.databaseOverview || {}),
                    getContextPackMeta: async () => __clone(__ctx.contextMeta || {})
                  };
                  if (typeof globalThis !== "undefined") {
                    globalThis.contextAPI = contextAPI;
                  }
                  let module = { exports: {} };
                  let exports = module.exports;
                  
                  \(script)

                  const __runContextScript = async () => {
                    if (typeof generateContext === "function") {
                      return await generateContext({ contextAPI, input: __ctx });
                    }
                    if (typeof module !== "undefined" && module && typeof module.exports === "function") {
                      return await module.exports({ contextAPI, input: __ctx });
                    }
                    if (typeof module !== "undefined" && module && module.exports && typeof module.exports.generateContext === "function") {
                      return await module.exports.generateContext({ contextAPI, input: __ctx });
                    }
                    if (typeof exports !== "undefined" && exports && typeof exports.generateContext === "function") {
                      return await exports.generateContext({ contextAPI, input: __ctx });
                    }
                    if (typeof result !== "undefined") {
                      return result;
                    }
                    throw new Error("Context script must expose generateContext(...) or set result.");
                  };
                  
                  let resultObj = await __runContextScript();
                  return typeof resultObj === 'object' ? JSON.stringify(resultObj) : JSON.stringify({ section: String(resultObj) });
                }
                """

                let request = BotwireJSExecutionRequest(
                    source: wrappedScript,
                    objective: "Evaluate scripted context \(key)",
                    inputJSON: "{}",
                    projectId: projectId,
                    workspacePath: workspacePath
                )
                let executor = BotwireRuntime.BotwireJSExecutorFactory.makeDefault()
                let report = await executor.execute(request, runID: UUID().uuidString)

                if report.success {
                    let resultPayload: String
                    if case .string(let resultStr) = report.result, let resultData = resultStr.data(using: .utf8), let resultJSON = try? JSONSerialization.jsonObject(with: resultData) {
                        let output: String
                        if let dict = resultJSON as? [String: Any] {
                            if let sections = dict["sections"] as? [String] {
                                output = sections.joined(separator: "\\n\\n")
                            } else if let section = dict["section"] as? String {
                                output = section
                            } else if let summary = dict["summary"] as? String {
                                output = summary
                            } else {
                                output = ""
                            }
                        } else if let arr = resultJSON as? [String] {
                            output = arr.joined(separator: "\\n\\n")
                        } else {
                            output = ""
                        }

                        let intro = definition.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        let nameUpper = definition.name.uppercased()
                        let finalResult: String
                        if output.isEmpty {
                             finalResult = "[AUTO CONTEXT: \(nameUpper)]\n\(intro)"
                        } else if intro.isEmpty {
                             finalResult = output
                        } else {
                             finalResult = "[AUTO CONTEXT: \(nameUpper)]\n\(intro)\n\n\(output)"
                        }

                        let enc = JSONEncoder()
                        if let resData = try? enc.encode(finalResult),
                           let str = String(data: resData, encoding: .utf8) {
                            resultPayload = str
                        } else {
                            resultPayload = "\"Failed to encode final result\""
                        }
                    } else {
                        resultPayload = "\"null\""
                    }
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: resultPayload))
                } else {
                    let errorMsg = report.errorMessage ?? "Context evaluation failed"
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(errorMsg)))
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
            }
        }
    }

    private func handleToolsList(_ req: JSHostRequest) {
        Task {
            do {
                guard let workspacePath = self.workspacePath else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"No workspace path configured\""))
                    return
                }
                let bundlePath = URL(fileURLWithPath: workspacePath).appendingPathComponent("project_bundle.json").path
                let bundle = try BotwireCore.ProjectBundleLoader.load(path: bundlePath)
                let tools = bundle.algorithms.map { algo in
                    [
                        "name": algo.name,
                        "description": "Local algorithm: \(algo.name)"
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: tools, options: [])
                if let payload = String(data: data, encoding: .utf8) {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: payload))
                } else {
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Failed to encode tools list\""))
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
            }
        }
    }

    private func handleToolsRun(_ req: JSHostRequest) {
        guard let data = req.args.data(using: .utf8),
              let argsObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = argsObj["name"] as? String else {
            responseQueue.push(JSHostResponse(id: req.id, success: false, payload: "\"Invalid tools run arguments\""))
            return
        }
        let inputArgs = argsObj["args"] as? String ?? "{}"

        emitBridgeEvent("tools.run.started", [
            "projectID": projectId,
            "requestID": req.id,
            "toolName": toolName
        ])

        Task {
            let startedAt = Date()
            do {
                guard let workspacePath = self.workspacePath else {
                    throw NSError(domain: "Bridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "No workspace path configured"])
                }
                let bundlePath = URL(fileURLWithPath: workspacePath).appendingPathComponent("project_bundle.json").path
                let bundle = try BotwireCore.ProjectBundleLoader.load(path: bundlePath)
                
                guard let algo = bundle.algorithms.first(where: { $0.name == toolName }) else {
                    throw NSError(domain: "Bridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tool not found"])
                }
                guard let codeBlock = algo.codeBlocks.first(where: { $0.role == .logic }) else {
                    throw NSError(domain: "Bridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Tool has no logic block"])
                }

                let request = BotwireJSExecutionRequest(
                    source: codeBlock.source,
                    objective: "Run tool \(toolName)",
                    inputJSON: inputArgs,
                    projectId: projectId,
                    workspacePath: workspacePath
                )
                let executor = BotwireRuntime.BotwireJSExecutorFactory.makeDefault()
                let report = await executor.execute(request, runID: UUID().uuidString)

                if report.success {
                    let resultPayload: String
                    if let resultJSON = report.result {
                        let enc = JSONEncoder()
                        if let resData = try? enc.encode(resultJSON),
                           let str = String(data: resData, encoding: .utf8) {
                            resultPayload = str
                        } else {
                            resultPayload = "null"
                        }
                    } else {
                        resultPayload = "null"
                    }
                    self.responseQueue.push(JSHostResponse(id: req.id, success: true, payload: resultPayload))
                    self.emitBridgeEvent("tools.run.finished", [
                        "projectID": self.projectId,
                        "requestID": req.id,
                        "toolName": toolName,
                        "success": true,
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                    ])
                } else {
                    let errorMsg = report.errorMessage ?? "Tool execution failed"
                    self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(errorMsg)))
                    self.emitBridgeEvent("tools.run.finished", [
                        "projectID": self.projectId,
                        "requestID": req.id,
                        "toolName": toolName,
                        "success": false,
                        "error": errorMsg,
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                    ])
                }
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false, payload: Self.javascriptStringLiteral(error.localizedDescription)))
                self.emitBridgeEvent("tools.run.finished", [
                    "projectID": self.projectId,
                    "requestID": req.id,
                    "toolName": toolName,
                    "success": false,
                    "error": error.localizedDescription,
                    "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                ])
            }
        }
    }

    private func emitBridgeEvent(_ kind: String, _ fields: [String: Any]) {
        var payload = fields
        payload["kind"] = kind
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        print("BW_EVENT \(string)")
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    // MARK: - Browser Automation

    private func handleBrowser(_ req: JSHostRequest) {
        // Lazy-launch the browser engine on first use
        if browserEngine == nil {
            let engine = LinuxBrowserAutomationEngine(projectId: projectId, responseQueue: responseQueue)
            if !engine.launch() {
                responseQueue.push(JSHostResponse(
                    id: req.id,
                    success: false,
                    payload: Self.javascriptStringLiteral("Failed to launch headless browser. Ensure chromium-browser is installed.")
                ))
                return
            }
            browserEngine = engine
        }

        browserEngine?.handleRequest(req)
    }
}
#endif
