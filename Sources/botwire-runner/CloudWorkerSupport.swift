import BotwireCore
import BotwireRuntime
import BotwireTransferCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

struct BREPCodeBlockTransferPayload: Codable, Sendable {
    var startupID: String
    var startupName: String
    var startupDescription: String
    var algorithmID: String
    var algorithmName: String
    var algorithmDescription: String
    var codeBlock: BREPCodeBlockDescriptor
    var senderPeerID: String
    var senderEndpoint: String
}

struct BREPCodeBlockDescriptor: Codable, Sendable {
    var id: String
    var name: String
    var action: String
    var role: String
    var language: String
    var code: String
}

struct BREPExecuteRequest: Codable, Sendable {
    var requestID: String
    var startupID: String
    var algorithmID: String
    var codeBlockID: String
    var input: String?
    var callerPeerID: String
    var callerEndpoint: String
}

struct CloudStoredCodeBlock: Codable, Sendable {
    var startupID: String
    var startupName: String
    var startupDescription: String
    var algorithmID: String
    var algorithmName: String
    var algorithmDescription: String
    var codeBlock: BREPCodeBlockDescriptor
    var receivedAt: Date
}

func storeLinuxStartupSnapshotMetadata(from startupSnapshot: [String: Any], into metadata: inout [String: String]) {
    BotwireCanonicalSnapshotRoundTrip.store(startupSnapshot: startupSnapshot, in: &metadata)
}

func linuxReturnedStartupSnapshot(from bundle: BotwireProjectBundle) -> [String: Any] {
    let originalSnapshot = BotwireCanonicalSnapshotRoundTrip.originalStartupSnapshot(in: bundle.metadata)
    let originalAlgorithms = originalSnapshot?["algorithms"] as? [[String: Any]] ?? []
    let algorithms = bundle.algorithms.map {
        linuxReturnedAlgorithmSnapshot(for: $0, in: bundle, originalAlgorithms: originalAlgorithms)
    }
    return BotwireCanonicalSnapshotRoundTrip.startupSnapshot(
        original: originalSnapshot,
        id: bundle.id,
        name: bundle.name,
        description: bundle.description,
        algorithms: algorithms
    )
}

func linuxReturnedAlgorithmSnapshot(
    for algorithm: BotwireAlgorithm,
    in bundle: BotwireProjectBundle,
    originalAlgorithms: [[String: Any]]? = nil
) -> [String: Any] {
    let algorithms = originalAlgorithms
        ?? BotwireCanonicalSnapshotRoundTrip.originalStartupSnapshot(in: bundle.metadata)?["algorithms"] as? [[String: Any]]
        ?? []
    let original = algorithms.first { $0["id"] as? String == algorithm.id }
    let originalBlocks = original?["codeblocks"] as? [[String: Any]] ?? []
    let codeblocks = algorithm.codeBlocks.map {
        linuxReturnedCodeBlockSnapshot(for: $0, originalBlocks: originalBlocks)
    }
    return BotwireCanonicalSnapshotRoundTrip.algorithmSnapshot(
        original: original,
        id: algorithm.id,
        name: algorithm.name,
        description: bundle.metadata["algorithm.\(algorithm.id).description"] ?? (original?["description"] as? String),
        entryPointRawValue: bundle.metadata["algorithm.\(algorithm.id).entryPoint"] ?? (original?["entryPointRawValue"] as? String),
        httpConfig: bundle.metadata["algorithm.\(algorithm.id).httpConfig"].flatMap(BotwireCanonicalSnapshotRoundTrip.jsonObject),
        dataWatchRules: LinuxDataWatchRunner.dataWatchSnapshotPayload(for: algorithm.id, in: bundle),
        timerProperty: BotwireRunnerCLI.timerSnapshotPayload(for: algorithm.id, in: bundle),
        codeblocks: codeblocks
    )
}

private func linuxReturnedCodeBlockSnapshot(
    for codeBlock: BotwireCodeBlock,
    originalBlocks: [[String: Any]]
) -> [String: Any] {
    BotwireCanonicalSnapshotRoundTrip.codeBlockSnapshot(
        original: originalBlocks.first { $0["id"] as? String == codeBlock.id },
        id: codeBlock.id,
        name: codeBlock.name,
        role: codeBlock.role.rawValue,
        language: codeBlock.language,
        code: codeBlock.source
    )
}

actor CloudResourceStore {
    private let root: URL
    private let workspaceRoot: URL
    private let projectsRoot: URL
    private let routesURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Caches to prevent disk reads on every proxy request
    private var projectCache: [String: BotwireProjectBundle] = [:]
    private var routesCache: [CloudStoredRoute]? = nil
    private var activeStateCache: [String: Bool] = [:]
    private var senderInfoCache: [String: CloudSenderInfo] = [:]

    init(workspacePath: String?) {
        let basePath = workspacePath ?? FileManager.default.currentDirectoryPath
        self.workspaceRoot = URL(fileURLWithPath: basePath)
        self.root = workspaceRoot.appendingPathComponent("brep-codeblocks", isDirectory: true)
        self.projectsRoot = workspaceRoot.appendingPathComponent("projects", isDirectory: true)
        self.routesURL = workspaceRoot.appendingPathComponent("routes.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    func store(_ payload: BREPCodeBlockTransferPayload) throws {
        let stored = CloudStoredCodeBlock(
            startupID: payload.startupID,
            startupName: payload.startupName,
            startupDescription: payload.startupDescription,
            algorithmID: payload.algorithmID,
            algorithmName: payload.algorithmName,
            algorithmDescription: payload.algorithmDescription,
            codeBlock: payload.codeBlock,
            receivedAt: Date()
        )
        let data = try encoder.encode(stored)
        try data.write(to: fileURL(for: payload.codeBlock.id), options: .atomic)
    }

    func remove(codeBlockID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: codeBlockID))
    }

    func codeBlock(id: String) throws -> CloudStoredCodeBlock? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(CloudStoredCodeBlock.self, from: data)
    }

    func sharedStartupIDs() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var ids = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let stored = try? decoder.decode(CloudStoredCodeBlock.self, from: data) else {
                continue
            }
            ids.insert(stored.startupID)
        }
        return Array(ids).sorted()
    }

    func storeProject(_ bundle: BotwireProjectBundle) throws {
        let projectRoot = projectRoot(startupID: bundle.id)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let data = try encoder.encode(bundle)
        try data.write(to: projectRoot.appendingPathComponent("project_bundle.json"), options: .atomic)
        projectCache[bundle.id] = bundle
    }

    func project(startupID: String) throws -> BotwireProjectBundle? {
        if let cached = projectCache[startupID] { return cached }
        let url = projectRoot(startupID: startupID).appendingPathComponent("project_bundle.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let bundle = try decoder.decode(BotwireProjectBundle.self, from: data)
        projectCache[startupID] = bundle
        return bundle
    }

    func projects() throws -> [BotwireProjectBundle] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return try directories.compactMap { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let bundleURL = directory.appendingPathComponent("project_bundle.json")
            guard FileManager.default.fileExists(atPath: bundleURL.path) else { return nil }
            let data = try Data(contentsOf: bundleURL)
            let bundle = try decoder.decode(BotwireProjectBundle.self, from: data)
            projectCache[bundle.id] = bundle
            return bundle
        }
    }

    func writeDatabases(_ payloads: [[String: Any]], startupID: String) {
        for payload in payloads {
            guard let db = payload["database"] as? [String: Any],
                  let dbID = db["id"] as? String,
                  let encoded = payload["data"] as? String,
                  let data = Data(base64Encoded: encoded) else {
                continue
            }
            let dbRoot = projectRoot(startupID: startupID)
                .appendingPathComponent("databases", isDirectory: true)
                .appendingPathComponent(safeFilename(dbID), isDirectory: true)
            try? FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
            try? data.write(to: dbRoot.appendingPathComponent("data.oxidb"), options: .atomic)

            // Keep a default project DB for current bridge calls until named DB routing is richer.
            let defaultDB = projectRoot(startupID: startupID).appendingPathComponent("data.oxidb")
            if !FileManager.default.fileExists(atPath: defaultDB.path) {
                try? data.write(to: defaultDB, options: .atomic)
            }
        }
    }

    /// Write project files received during deployment to the runner's local disk.
    /// Files are stored at ProjectFiles/<startupID>/<relativePath> so they are
    /// accessible through the same path the JS file bridge uses at runtime.
    func writeFiles(_ payloads: [[String: Any]], startupID: String) {
        let filesRoot = projectRoot(startupID: startupID)
            .appendingPathComponent("ProjectFiles", isDirectory: true)
        for payload in payloads {
            guard let relativePath = payload["relativePath"] as? String,
                  !relativePath.isEmpty,
                  let encoded = payload["data"] as? String,
                  let data = Data(base64Encoded: encoded) else {
                continue
            }
            let destination = filesRoot.appendingPathComponent(relativePath, isDirectory: false)
            let hashDestination = destination.appendingPathExtension("bwhash")
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try data.write(to: destination, options: .atomic)
                // Compute and store sidecar hash for future proxy requests
                let fileHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try fileHash.data(using: .utf8)?.write(to: hashDestination, options: .atomic)
                let metadata: [String: String] = [
                    "relativePath": relativePath,
                    "mimeType": (payload["mimeType"] as? String) ?? "application/octet-stream",
                    "isPublic": String((payload["isPublic"] as? Bool) ?? false)
                ]
                if let metadataData = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted]) {
                    try? metadataData.write(to: destination.appendingPathExtension("bwmeta"), options: .atomic)
                }
            } catch {
                print("⚠️ [Runner] Could not write project file '\(relativePath)': \(error)")
            }
        }
    }

    func publicFile(startupID: String, relativePath: String) -> (data: Data, mimeType: String)? {
        let normalized = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
        let url = projectRoot(startupID: startupID)
            .appendingPathComponent("ProjectFiles", isDirectory: true)
            .appendingPathComponent(normalized, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let metaURL = url.appendingPathExtension("bwmeta")
        guard let metaData = try? Data(contentsOf: metaURL),
              let object = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
              object["isPublic"] == "true" else {
            return nil
        }
        return (data, object["mimeType"] ?? "application/octet-stream")
    }

    func readAllDatabases(startupID: String) throws -> [[String: Any]] {
        var returnedDatabases: [[String: Any]] = []
        let dbsRoot = projectRoot(startupID: startupID).appendingPathComponent("databases", isDirectory: true)
        
        guard FileManager.default.fileExists(atPath: dbsRoot.path) else { return [] }
        
        if let entries = try? FileManager.default.contentsOfDirectory(at: dbsRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries {
                let dbID = entry.lastPathComponent
                let dbFile = entry.appendingPathComponent("data.oxidb")
                if let data = try? Data(contentsOf: dbFile) {
                    returnedDatabases.append([
                        "database": [
                            "id": dbID,
                            "name": dbID, // Fallback since we don't have the original metadata on disk here easily
                            "scope": "root", // Fallback
                            "algorithmID": nil
                        ],
                        "data": data.base64EncodedString()
                    ])
                }
            }
        }
        return returnedDatabases
    }

    func removeDatabase(startupID: String, databaseID: String) throws {
        let dbRoot = projectRoot(startupID: startupID)
            .appendingPathComponent("databases", isDirectory: true)
            .appendingPathComponent(safeFilename(databaseID), isDirectory: true)
        if FileManager.default.fileExists(atPath: dbRoot.path) {
            try FileManager.default.removeItem(at: dbRoot)
        }
    }

    func readAllFiles(startupID: String) throws -> [[String: Any]] {
        let filesRoot = projectRoot(startupID: startupID)
            .appendingPathComponent("ProjectFiles", isDirectory: true)
        
        guard FileManager.default.fileExists(atPath: filesRoot.path) else { return [] }
        let enumerator = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var returnedFiles: [[String: Any]] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension != "bwhash" && fileURL.pathExtension != "bwmeta" else { continue }
            if let attrs = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), attrs.isRegularFile == true,
               let data = try? Data(contentsOf: fileURL) {
                let relativePath = fileURL.path.replacingOccurrences(of: filesRoot.path + "/", with: "")
                returnedFiles.append([
                    "relativePath": relativePath,
                    "data": data.base64EncodedString()
                ])
            }
        }
        return returnedFiles
    }



    func registerRoute(path: String?, startupID: String, algorithmID: String) throws {
        guard let path, !path.isEmpty else { return }
        var routes = try loadRoutes()
        routes.removeAll { $0.path == path }
        routes.append(CloudStoredRoute(path: path, startupID: startupID, algorithmID: algorithmID))
        try saveRoutes(routes)
    }

    func relayRoutes() throws -> [[String: String]] {
        try loadRoutes().map {
            [
                "path": $0.path,
                "startupID": $0.startupID,
                "algorithmID": $0.algorithmID
            ]
        }
    }

    func routeTarget(path: String) throws -> CloudStoredRoute? {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return try loadRoutes().first { route in
            normalized == route.path || normalized.hasPrefix(route.path + "/")
        }
    }

    func removeAlgorithm(startupID: String, algorithmID: String) throws {
        var routes = try loadRoutes()
        routes.removeAll { $0.startupID == startupID && $0.algorithmID == algorithmID }
        try saveRoutes(routes)

        if var bundle = try project(startupID: startupID) {
            bundle.algorithms.removeAll { $0.id == algorithmID }
            try storeProject(bundle)
        }
        
        // Ensure caches reflect removals if not handled by storeProject
        projectCache.removeValue(forKey: startupID)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let stored = try? decoder.decode(CloudStoredCodeBlock.self, from: data),
                  stored.startupID == startupID,
                  stored.algorithmID == algorithmID else {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    func removeStartup(startupID: String) throws {
        var routes = try loadRoutes()
        routes.removeAll { $0.startupID == startupID }
        try saveRoutes(routes)
        try? FileManager.default.removeItem(at: projectRoot(startupID: startupID))
        
        projectCache.removeValue(forKey: startupID)
        activeStateCache.removeValue(forKey: startupID)
        senderInfoCache.removeValue(forKey: startupID)

        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let stored = try? decoder.decode(CloudStoredCodeBlock.self, from: data),
                  stored.startupID == startupID else {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Running/Idle State

    /// Set the running/idle state for a deployed startup.
    func setStartupActive(startupID: String, isActive: Bool) {
        activeStateCache[startupID] = isActive
        let stateURL = projectRoot(startupID: startupID).appendingPathComponent("state.json")
        let state = CloudStartupState(startupID: startupID, isActive: isActive)
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: projectRoot(startupID: startupID), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
        print("☁️ [CloudStore] Startup \(startupID.prefix(8)) set to \(isActive ? "running" : "idle")")
    }

    /// Check if a startup is active (defaults to true if no state file exists).
    func isStartupActive(startupID: String) -> Bool {
        if let cached = activeStateCache[startupID] { return cached }
        let stateURL = projectRoot(startupID: startupID).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(CloudStartupState.self, from: data) else {
            activeStateCache[startupID] = true
            return true // default active
        }
        activeStateCache[startupID] = state.isActive
        return state.isActive
    }

    // MARK: - Performance Profiling State

    private var profilingStateCache: [String: Bool] = [:]

    /// Set performance profiling on/off for a deployed startup.
    func setPerformanceProfiling(startupID: String, enabled: Bool) {
        profilingStateCache[startupID] = enabled
        let url = projectRoot(startupID: startupID).appendingPathComponent("profiling_state.json")
        let state: [String: Any] = ["startupID": startupID, "enabled": enabled]
        guard JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? FileManager.default.createDirectory(at: projectRoot(startupID: startupID), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        print("📊 [CloudStore] Startup \(startupID.prefix(8)) profiling \(enabled ? "enabled" : "disabled")")
    }

    /// Check if performance profiling is enabled for a startup (defaults to false).
    func isProfilingEnabled(startupID: String) -> Bool {
        if let cached = profilingStateCache[startupID] { return cached }
        let url = projectRoot(startupID: startupID).appendingPathComponent("profiling_state.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = obj["enabled"] as? Bool else {
            profilingStateCache[startupID] = false
            return false
        }
        profilingStateCache[startupID] = enabled
        return enabled
    }

    private func fileURL(for codeBlockID: String) -> URL {
        root.appendingPathComponent(safeFilename(codeBlockID)).appendingPathExtension("json")
    }

    private func projectRoot(startupID: String) -> URL {
        projectsRoot.appendingPathComponent(safeFilename(startupID), isDirectory: true)
    }

    private func loadRoutes() throws -> [CloudStoredRoute] {
        if let cached = routesCache { return cached }
        guard FileManager.default.fileExists(atPath: routesURL.path) else { return [] }
        let data = try Data(contentsOf: routesURL)
        let routes = try decoder.decode([CloudStoredRoute].self, from: data)
        routesCache = routes
        return routes
    }

    private func saveRoutes(_ routes: [CloudStoredRoute]) throws {
        let sorted = routes.sorted { lhs, rhs in
            if lhs.path == rhs.path { return lhs.algorithmID < rhs.algorithmID }
            return lhs.path < rhs.path
        }
        routesCache = sorted
        let data = try encoder.encode(sorted)
        try data.write(to: routesURL, options: .atomic)
    }

    private func safeFilename(_ raw: String) -> String {
        raw.map { char in
            char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "_"
        }.map(String.init).joined()
    }

    // MARK: - Sender Info (for resource proxying)

    /// Store which device deployed this startup, so we can proxy requests back.
    func storeSenderInfo(startupID: String, peerID: String, endpoint: String) {
        let info = CloudSenderInfo(peerID: peerID, endpoint: endpoint)
        senderInfoCache[startupID] = info
        let url = projectRoot(startupID: startupID).appendingPathComponent("sender_info.json")
        try? FileManager.default.createDirectory(at: projectRoot(startupID: startupID), withIntermediateDirectories: true)
        guard let data = try? encoder.encode(info) else { return }
        try? data.write(to: url, options: .atomic)
        print("☁️ [CloudStore] Stored sender info for \(startupID.prefix(8)): peer=\(peerID.prefix(8)), endpoint=\(endpoint)")
    }

    /// Retrieve which device deployed this startup.
    func senderInfo(forStartup startupID: String) -> CloudSenderInfo? {
        if let cached = senderInfoCache[startupID] { return cached }
        let url = projectRoot(startupID: startupID).appendingPathComponent("sender_info.json")
        guard let data = try? Data(contentsOf: url),
              let info = try? decoder.decode(CloudSenderInfo.self, from: data) else { return nil }
        senderInfoCache[startupID] = info
        return info
    }

    // MARK: - Performance Trace Storage

    private func tracesRoot(startupID: String) -> URL {
        projectRoot(startupID: startupID).appendingPathComponent("traces", isDirectory: true)
    }

    /// Save a completed performance trace to disk.
    func saveTrace(_ trace: PerformanceTrace) {
        let dir = tracesRoot(startupID: trace.startupID.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(trace.id.uuidString).json")
        guard let data = try? encoder.encode(trace) else { return }
        try? data.write(to: url, options: .atomic)
        print("📊 [Trace] Saved trace \(trace.id.uuidString.prefix(8)) for startup \(trace.startupID.uuidString.prefix(8)) (\(trace.spans.count) spans, \(trace.totalDurationMs)ms)")
    }

    /// Fetch performance traces for a startup, newest first.
    func fetchTraces(startupID: String, limit: Int = 50) -> [PerformanceTrace] {
        let dir = tracesRoot(startupID: startupID)
        guard FileManager.default.fileExists(atPath: dir.path),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        var traces: [PerformanceTrace] = []
        for file in jsonFiles {
            guard let data = try? Data(contentsOf: file),
                  let trace = try? decoder.decode(PerformanceTrace.self, from: data) else {
                continue
            }
            traces.append(trace)
        }
        traces.sort { $0.startedAt > $1.startedAt }
        return Array(traces.prefix(limit))
    }

    /// Delete all traces for a startup.
    func deleteTraces(startupID: String) {
        let dir = tracesRoot(startupID: startupID)
        try? FileManager.default.removeItem(at: dir)
    }
}


struct CloudStoredRoute: Codable, Sendable {
    var path: String
    var startupID: String
    var algorithmID: String
}

struct CloudStartupState: Codable, Sendable {
    var startupID: String
    var isActive: Bool
}

struct CloudSenderInfo: Codable, Sendable {
    var peerID: String
    var endpoint: String
}

enum CloudExecutionResultFactory {
    static func execute(
        stored: CloudStoredCodeBlock,
        request: BREPExecuteRequest,
        traceStore: CloudResourceStore? = nil
    ) async -> CloudAlgorithmExecutionResult {
        let startedAt = Date()
        let profilingEnabled: Bool
        if let traceStore {
            profilingEnabled = await traceStore.isProfilingEnabled(startupID: stored.startupID)
        } else {
            profilingEnabled = false
        }
        let collector: PerformanceTraceCollector? = profilingEnabled ? PerformanceTraceCollector(
            startupID: UUID(uuidString: stored.startupID) ?? UUID(),
            startupName: stored.startupName,
            algorithmID: UUID(uuidString: stored.algorithmID) ?? UUID(),
            algorithmName: stored.algorithmName,
            trigger: "manual"
        ) : nil
        let algoSpanID = collector?.beginSpan(
            kind: .algorithmRun,
            label: "algorithm.\(stored.algorithmName)",
            metadata: ["algorithmID": stored.algorithmID]
        )
        let cbSpanID = collector?.beginSpan(
            kind: .codeblockExecution,
            label: "codeblock.\(stored.codeBlock.name)",
            parentID: algoSpanID,
            metadata: ["codeBlockID": stored.codeBlock.id]
        )
        let source = codeBlockExecutionSource(stored.codeBlock.code)
        let report = await BotwireJSExecutorFactory.makeDefault().execute(
            BotwireJSExecutionRequest(
                source: source,
                objective: "Execute remote code block \(stored.codeBlock.name).",
                inputJSON: request.input,
                projectId: request.startupID,
                algorithmId: stored.algorithmID,
                codeBlockId: stored.codeBlock.id,
                timeout: 30,
                databaseMutationHandler: { event in
                    Task {
                        await LinuxDataWatchRunner.handle(event: event, workspacePath: nil)
                    }
                }
            ),
            runID: request.requestID
        )
        let finishedAt = Date()
        if let cbSpanID {
            collector?.endSpan(id: cbSpanID, success: report.success,
                               error: report.errorMessage,
                               metadata: ["durationMs": "\(report.durationMs)"])
        }
        if let algoSpanID {
            collector?.endSpan(id: algoSpanID, success: report.success)
        }
        if let collector, let traceStore {
            let trace = collector.finalize(success: report.success)
            await traceStore.saveTrace(trace)
        }
        let outputJSON = jsonString(report.result)
        let appReport = CloudCodeBlockExecutionReport(
            id: stored.codeBlock.id,
            name: stored.codeBlock.name,
            success: report.success,
            outputJSON: outputJSON,
            httpResponseJSON: jsonString(report.httpResponseJSON),
            logs: report.logs.map { CloudRuntimeLogEntry(level: "info", message: $0) },
            networkTraces: [],
            durationMs: report.durationMs,
            metrics: CloudRuntimeTechnicalMetrics(
                inputBytes: request.input?.utf8.count ?? 0,
                codeBytes: stored.codeBlock.code.utf8.count,
                outputBytes: outputJSON?.utf8.count ?? 0,
                logCount: report.logs.count,
                memoryBeforeBytes: nil,
                memoryAfterBytes: nil,
                memoryDeltaBytes: nil
            ),
            error: report.success ? nil : CloudAlgorithmRuntimeError(
                kind: "runtime",
                message: report.errorMessage ?? "Remote Linux JavaScriptCore execution failed.",
                stack: nil
            )
        )
        return CloudAlgorithmExecutionResult(
            algorithmID: UUID(uuidString: stored.algorithmID) ?? UUID(),
            success: report.success,
            trigger: "manual",
            outputJSON: outputJSON,
            httpResponseJSON: appReport.httpResponseJSON,
            reports: [appReport],
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    static func executeCodeBlock(
        startupID: String,
        algorithmID: String,
        codeBlock: BotwireCodeBlock,
        inputJSON: String?,
        workspacePath: String?,
        runID: String = UUID().uuidString,
        trigger: String = "manual",
        traceStore: CloudResourceStore? = nil
    ) async -> CloudAlgorithmExecutionResult {
        let startedAt = Date()
        let profilingEnabled: Bool
        if let traceStore {
            profilingEnabled = await traceStore.isProfilingEnabled(startupID: startupID)
        } else {
            profilingEnabled = false
        }
        let collector: PerformanceTraceCollector? = profilingEnabled ? PerformanceTraceCollector(
            startupID: UUID(uuidString: startupID) ?? UUID(),
            startupName: startupID,
            algorithmID: UUID(uuidString: algorithmID) ?? UUID(),
            algorithmName: algorithmID,
            trigger: trigger
        ) : nil
        let algoSpanID = collector?.beginSpan(
            kind: .algorithmRun,
            label: "algorithm.\(algorithmID.prefix(8))",
            metadata: ["algorithmID": algorithmID, "trigger": trigger]
        )
        let cbSpanID = collector?.beginSpan(
            kind: .codeblockExecution,
            label: "codeblock.\(codeBlock.name)",
            parentID: algoSpanID,
            metadata: ["codeBlockID": codeBlock.id]
        )
        let report = await BotwireJSExecutorFactory.makeDefault().execute(
            BotwireJSExecutionRequest(
                source: codeBlockExecutionSource(codeBlock.source),
                objective: "Execute remote code block \(codeBlock.name).",
                inputJSON: inputJSON,
                projectId: startupID,
                algorithmId: algorithmID,
                codeBlockId: codeBlock.id,
                workspacePath: workspacePath,
                timeout: 30,
                databaseMutationHandler: { event in
                    Task {
                        await LinuxDataWatchRunner.handle(event: event, workspacePath: workspacePath)
                    }
                }
            ),
            runID: runID
        )
        let finishedAt = Date()
        if let cbSpanID {
            collector?.endSpan(id: cbSpanID, success: report.success,
                               error: report.errorMessage,
                               metadata: ["durationMs": "\(report.durationMs)"])
        }
        if let algoSpanID {
            collector?.endSpan(id: algoSpanID, success: report.success)
        }
        if let collector, let traceStore {
            let trace = collector.finalize(success: report.success)
            await traceStore.saveTrace(trace)
        }
        let outputJSON = jsonString(report.result)
        let appReport = CloudCodeBlockExecutionReport(
            id: codeBlock.id,
            name: codeBlock.name,
            success: report.success,
            outputJSON: outputJSON,
            httpResponseJSON: jsonString(report.httpResponseJSON),
            logs: report.logs.map { CloudRuntimeLogEntry(level: "info", message: $0) },
            networkTraces: [],
            durationMs: report.durationMs,
            metrics: CloudRuntimeTechnicalMetrics(
                inputBytes: inputJSON?.utf8.count ?? 0,
                codeBytes: codeBlock.source.utf8.count,
                outputBytes: outputJSON?.utf8.count ?? 0,
                logCount: report.logs.count,
                memoryBeforeBytes: nil,
                memoryAfterBytes: nil,
                memoryDeltaBytes: nil
            ),
            error: report.success ? nil : CloudAlgorithmRuntimeError(
                kind: "runtime",
                message: report.errorMessage ?? "Remote Linux JavaScriptCore execution failed.",
                stack: nil
            )
        )
        return CloudAlgorithmExecutionResult(
            algorithmID: UUID(uuidString: algorithmID) ?? UUID(),
            success: report.success,
            trigger: trigger,
            outputJSON: outputJSON,
            httpResponseJSON: appReport.httpResponseJSON,
            reports: [appReport],
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    static func failure(
        algorithmID: String,
        codeBlockID: String,
        codeBlockName: String,
        message: String
    ) -> CloudAlgorithmExecutionResult {
        let now = Date()
        let report = CloudCodeBlockExecutionReport(
            id: codeBlockID,
            name: codeBlockName,
            success: false,
            outputJSON: nil,
            httpResponseJSON: nil,
            logs: [CloudRuntimeLogEntry(level: "error", message: message)],
            networkTraces: [],
            durationMs: 0,
            metrics: nil,
            error: CloudAlgorithmRuntimeError(kind: "runtime", message: message, stack: nil)
        )
        return CloudAlgorithmExecutionResult(
            algorithmID: UUID(uuidString: algorithmID) ?? UUID(),
            success: false,
            trigger: "manual",
            outputJSON: nil,
            httpResponseJSON: nil,
            reports: [report],
            startedAt: now,
            finishedAt: now
        )
    }

    private static func codeBlockExecutionSource(_ source: String) -> String {
        """
        async function main() {
        const input = Botwire.input;
        var result;
        \(source)
        if (typeof result !== "undefined") {
          return result;
        }
        return null;
        }
        """
    }

    private static func jsonString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

struct CloudAlgorithmExecutionResult: Codable, Sendable {
    var algorithmID: UUID
    var success: Bool
    var trigger: String
    var outputJSON: String?
    var httpResponseJSON: String?
    var reports: [CloudCodeBlockExecutionReport]
    var startedAt: Date
    var finishedAt: Date
}

struct CloudCodeBlockExecutionReport: Codable, Sendable {
    var id: String
    var name: String
    var success: Bool
    var outputJSON: String?
    var httpResponseJSON: String?
    var logs: [CloudRuntimeLogEntry]
    var networkTraces: [String]
    var durationMs: Int
    var metrics: CloudRuntimeTechnicalMetrics?
    var error: CloudAlgorithmRuntimeError?
}

struct CloudRuntimeLogEntry: Codable, Sendable {
    var id = UUID().uuidString
    var level: String
    var message: String
    var timestamp = Date()
}

struct CloudRuntimeTechnicalMetrics: Codable, Sendable {
    var inputBytes: Int
    var codeBytes: Int
    var outputBytes: Int
    var logCount: Int
    var memoryBeforeBytes: UInt64?
    var memoryAfterBytes: UInt64?
    var memoryDeltaBytes: Int64?
}

struct CloudAlgorithmRuntimeError: Codable, Sendable {
    var kind: String
    var message: String
    var stack: String?
}
