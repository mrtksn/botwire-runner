import BotwireCore
import BotwireRelay
import BotwireRuntime
import BotwirePersistence
import BotwireShared
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct BotwireRunnerCLI {
    static func main() async {
        configureProcessOutput()
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.writeLine("error: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }

    private static func configureProcessOutput() {
        #if os(Linux)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        #endif
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        let options = CLIOptions(arguments: Array(arguments.dropFirst()))

        switch command {
        case "help", "--help", "-h":
            printHelp()

        case "status":
            try await printRelayStatus(relayURL: options.url("relay", default: URL(string: "https://algo.botwire.app")!))

        case "init-config":
            let path = options.string("output") ?? RunnerConfigStore.defaultPath
            try writeConfig(path: path)

        case "register":
            try await registerRunner(options: options)

        case "pair":
            try await pairRunner(options: options)

        case "connect":
            try await connectTunnel(options: options)

        case "cloud":
            try await runCloudWorker(options: options)

        case "serve":
            try await serveProject(options: options)

        case "appdata-add-llm":
            try await addLLMProfile(options: options)

        case "appdata-list-llm":
            try await listLLMProfiles(options: options)

        case "sample-project":
            let path = options.string("output") ?? "Sample.botwire.json"
            try ProjectBundleLoader.writeSample(path: path)
            print("Wrote sample project: \(path)")

        case "inspect":
            let project = try loadProject(options: options)
            printProject(project)

        case "run":
            let project = try loadProject(options: options)
            let objective = options.string("objective") ?? "Run the project."
            let request = BotwireRunRequest(
                objective: objective,
                inputJSON: options.string("input-json"),
                project: project,
                workspacePath: options.string("config").flatMap { path in
                    (try? RunnerConfigStore.load(path: path))?.workspacePath
                } ?? RunnerConfigStore.defaultPath
            )
            let report = await BotwireRunner().run(request)
            printReport(report)
            if !report.success {
                Foundation.exit(2)
            }

        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func printRelayStatus(relayURL: URL) async throws {
        let client = BotwireRelayHTTPClient(baseURL: relayURL)
        let health = try await client.health()
        let status = try await client.status()

        print("Relay: \(relayURL.absoluteString)")
        print("Health: \(health.prettyJSONString)")
        print("Status:")
        print("  version: \(status.version ?? "unknown")")
        print("  connected devices: \(status.connectedDevices.map(String.init) ?? "unknown")")
        print("  pending requests: \(status.pendingRequests.map(String.init) ?? "unknown")")
    }

    private static func writeConfig(path: String) throws {
        let config = BotwireRunnerConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("Wrote runner config: \(path)")
    }

    private static func loadProject(options: CLIOptions) throws -> BotwireProjectBundle {
        guard let path = options.string("project") else {
            throw CLIError.missingOption("project")
        }
        return try ProjectBundleLoader.load(path: path)
    }

    private static func printProject(_ project: BotwireProjectBundle) {
        print("Project: \(project.name)")
        print("  id: \(project.id)")
        print("  schema: \(project.schemaVersion)")
        if let description = project.description, !description.isEmpty {
            print("  description: \(description)")
        }
        if let agentBlock = project.agentBlock {
            print("  agentBlock: \(agentBlock.name) (\(agentBlock.id))")
            print("  agentBlock source bytes: \(agentBlock.source.utf8.count)")
        } else {
            print("  agentBlock: none")
        }
        print("  algorithms: \(project.algorithms.count)")
        for algorithm in project.algorithms {
            print("    - \(algorithm.name) (\(algorithm.codeBlocks.count) code blocks)")
        }
    }

    private static func printReport(_ report: BotwireJSExecutionReport) {
        print("Run \(report.success ? "succeeded" : "failed") in \(report.durationMs)ms")
        if !report.events.isEmpty {
            print("Events:")
            for event in report.events {
                print("  [\(event.kind.rawValue)] \(event.message)")
            }
        }
        if !report.logs.isEmpty {
            print("Logs:")
            for log in report.logs {
                print("  \(log)")
            }
        }
        if let result = report.result {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result),
               let string = String(data: data, encoding: .utf8) {
                print("Result:")
                print(string)
            }
        }
        if let errorMessage = report.errorMessage {
            print("Error: \(errorMessage)")
        }
    }

    private static func printHelp() {
        print(
            """
            botwire-runner

            Commands:
              status [--relay https://algo.botwire.app]
                  Check relay health and status.

              init-config [--output .botwire-runner.json]
                  Write a default runner config.

              register [--config /etc/botwire-runner/config.json] [--dev-token token]
                  Register this runner with the dev relay and persist tunnel credentials.

              pair --token bw_pair_... [--relay https://algo.botwire.app] [--config /etc/botwire-runner/config.json] [--name "Office VPS"] [--workspace /var/lib/botwire-runner/workspace]
                  Claim a short-lived runner pairing token from the app and persist tunnel credentials.

              connect [--config /etc/botwire-runner/config.json] [--duration 30]
                  Connect to the relay tunnel, authenticate, and keep the connection open.

              cloud [--config /var/lib/botwire-cloud/users/<user>/config.json]
                  Run as a managed Botwire Cloud worker for one user.

              serve --project Project.botwire.json [--route /path] [--config /etc/botwire-runner/config.json] [--duration 0]
                  Register an HTTP route and execute the project for forwarded relay requests.

              appdata-add-llm --name "OpenAI" --url "..." --key "sk-..." --model "gpt-4" [--config /etc/botwire-runner/config.json]
                  Add an LLM profile to the runner's AppData store.

              appdata-list-llm [--config /etc/botwire-runner/config.json]
                  List all configured LLM profiles.

              sample-project [--output Sample.botwire.json]
                  Write a minimal portable project JSON file.

              inspect --project Project.botwire.json
                  Print project bundle details.

              run --project Project.botwire.json [--objective "..."] [--input-json "{}"]
                  Execute the project's AgentBlock.

            Defaults:
              relay: https://algo.botwire.app
            """
        )
    }

    private static func addLLMProfile(options: CLIOptions) async throws {
        let path = options.string("config") ?? RunnerConfigStore.defaultPath
        let config = try RunnerConfigStore.load(path: path)
        let root = config.workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace"
        let dbPath = URL(fileURLWithPath: root).appendingPathComponent("appdata.oxidb")
        let store = BotwirePersistence.NativeOxiModelStore(root: dbPath)

        guard let name = options.string("name"),
              let baseURL = options.string("url"),
              let apiKey = options.string("key"),
              let model = options.string("model") else {
            throw CLIError.missingOption("name, url, key, and model")
        }

        let profile = BotwirePersistence.StoredLLMProfile(
            id: UUID().uuidString,
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            proxyPath: options.string("proxy-path")
        )

        try await store.save(profile)
        print("Added LLM Profile: \(name) (\(profile.id))")
        print("Database: \(dbPath.path)")
    }

    private static func listLLMProfiles(options: CLIOptions) async throws {
        let path = options.string("config") ?? RunnerConfigStore.defaultPath
        let config = try RunnerConfigStore.load(path: path)
        let root = config.workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace"
        let dbPath = URL(fileURLWithPath: root).appendingPathComponent("appdata.oxidb")
        let store = BotwirePersistence.NativeOxiModelStore(root: dbPath)

        let profiles = try await store.fetch(BotwirePersistence.StoredLLMProfile.self)
        if profiles.isEmpty {
            print("No LLM profiles found in \(dbPath.path)")
            return
        }

        print("Configured LLM Profiles:")
        for profile in profiles {
            print("  - \(profile.name) (\(profile.id))")
            print("    URL: \(profile.baseURL)")
            print("    Model: \(profile.model)")
            if let proxy = profile.proxyPath {
                print("    Proxy: \(proxy)")
            }
        }
    }

    private static func registerRunner(options: CLIOptions) async throws {
        let path = options.string("config") ?? RunnerConfigStore.defaultPath
        var config = (try? RunnerConfigStore.load(path: path)) ?? BotwireRunnerConfig()
        if let relay = options.string("relay").flatMap(URL.init(string:)) {
            config.relayBaseURL = relay
        }
        let devToken = options.string("dev-token")
            ?? ProcessInfo.processInfo.environment["BOTWIRE_DEV_RUNNER_TOKEN"]
        guard let devToken, !devToken.isEmpty else {
            throw CLIError.missingOption("dev-token or BOTWIRE_DEV_RUNNER_TOKEN")
        }

        let client = BotwireRelayHTTPClient(baseURL: config.relayBaseURL)
        let response = try await client.registerDevRunner(
            runnerID: config.runnerID,
            runnerName: config.runnerName,
            devToken: devToken
        )
        config.shareableID = response.shareableID
        config.relayAuthToken = response.relayAuthToken
        config.sessionToken = response.sessionToken
        try RunnerConfigStore.save(config, path: path)

        print("Registered runner: \(config.runnerName)")
        print("  runnerID: \(config.runnerID)")
        print("  shareableID: \(response.shareableID)")
        print("  config: \(path)")
    }

    private static func pairRunner(options: CLIOptions) async throws {
        let path = options.string("config") ?? RunnerConfigStore.defaultPath
        var config = (try? RunnerConfigStore.load(path: path)) ?? BotwireRunnerConfig()
        if let relay = options.string("relay").flatMap(URL.init(string:)) {
            config.relayBaseURL = relay
        }
        if let name = options.string("name"), !name.isEmpty {
            config.runnerName = name
        }
        if let workspace = options.string("workspace"), !workspace.isEmpty {
            config.workspacePath = workspace
        }
        guard let token = options.string("token"), !token.isEmpty else {
            throw CLIError.missingOption("token")
        }

        let client = BotwireRelayHTTPClient(baseURL: config.relayBaseURL)
        let response = try await client.claimRunnerPairingToken(
            token: token,
            runnerID: config.runnerID,
            runnerName: config.runnerName,
            platform: "linux"
        )

        config.relayBaseURL = response.relayBaseURL
        config.tunnelURL = response.tunnelURL
        config.runnerID = response.runnerID
        config.runnerName = response.runnerName
        config.shareableID = response.shareableID
        config.relayAuthToken = response.relayAuthToken
        config.sessionToken = response.sessionToken
        try RunnerConfigStore.save(config, path: path)

        print("Paired runner: \(config.runnerName)")
        print("  runnerID: \(config.runnerID)")
        print("  shareableID: \(response.shareableID)")
        print("  relay: \(response.relayBaseURL.absoluteString)")
        print("  config: \(path)")
    }

    private static func connectTunnel(options: CLIOptions) async throws {
        let path = options.string("config") ?? RunnerConfigStore.defaultPath
        let duration = TimeInterval(options.string("duration").flatMap(Int.init) ?? 30)
        let config = try RunnerConfigStore.load(path: path)
        let tunnel = BotwireRelayTunnelClient()
        try await tunnel.connect(config: config) { message in
            if !message.contains("\"pong\"") && !message.contains("\"ping\"") {
                print("relay: \(message)")
            }
        }
        print("Tunnel connecting as \(config.runnerName) (\(config.shareableID ?? config.runnerID))")

        let started = Date()
        while Date().timeIntervalSince(started) < duration {
            try await tunnel.sendPing()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        await tunnel.disconnect()
        print("Tunnel disconnected")
    }

    private static func runCloudWorker(options: CLIOptions) async throws {
        let path = options.string("config") ?? RunnerConfigStore.defaultPath
        let config = try RunnerConfigStore.load(path: path)
        let store = CloudResourceStore(workspacePath: config.workspacePath)
        let timerScheduler = Task {
            await runTimerScheduler(config: config, store: store)
        }
        defer {
            timerScheduler.cancel()
        }

        while true {
            let tunnel = BotwireRelayTunnelClient()
            do {
                await BotwireRunnerCLI.fetchSettings(config: config)

                try await tunnel.connect(config: config) { message in
                    if !message.contains("\"pong\"") && !message.contains("\"ping\"") {
                        print("relay: \(message)")
                    }
                    Task {
                        await handleCloudMessage(message, config: config, store: store, tunnel: tunnel)
                    }
                }
                if let routes = try? await store.relayRoutes(), !routes.isEmpty {
                    try? await tunnel.registerRoutes(routes)
                }

                // Re-register resource proxy handlers for existing deployments
                for startupID in await store.sharedStartupIDs() {
                    if let sender = await store.senderInfo(forStartup: startupID) {
                        registerResourceProxy(
                            startupID: startupID,
                            senderPeerID: sender.peerID,
                            tunnel: tunnel
                        )
                    }
                }

                print("Botwire Cloud worker connected as \(config.runnerName) (\(config.shareableID ?? config.runnerID))")
                while true {
                    do {
                        try await tunnel.sendPing()
                    } catch {
                        FileHandle.standardError.writeLine("relay: ping failed, reconnecting: \(error.localizedDescription)")
                        break
                    }
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            } catch {
                FileHandle.standardError.writeLine("relay: connection failed, retrying: \(error.localizedDescription)")
            }

            await tunnel.disconnect()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private static func serveProject(options: CLIOptions) async throws {
        let path = options.string("config") ?? RunnerConfigStore.defaultPath
        let duration = TimeInterval(options.string("duration").flatMap(Int.init) ?? 0)
        let route = normalizedRoute(options.string("route") ?? "/")
        let project = try loadProject(options: options)
        let config = try RunnerConfigStore.load(path: path)
        let runner = BotwireRunner()
        let tunnel = BotwireRelayTunnelClient()
        
        await BotwireRunnerCLI.fetchSettings(config: config)

        try await tunnel.connect(config: config) { message in
            if !message.contains("\"pong\"") && !message.contains("\"ping\"") {
                print("relay: \(message)")
            }
            Task {
                await handleForwardedMessage(
                    message,
                    project: project,
                    runner: runner,
                    tunnel: tunnel
                )
            }
        }

        try await tunnel.registerRoutes([[
            "path": route,
            "startupID": project.id,
            "algorithmID": project.algorithms.first?.id ?? ""
        ]])

        let publicRoute = config.shareableID.map { "\(config.relayBaseURL.absoluteString)/\($0)\(route == "/" ? "" : route)" }
        print("Serving \(project.name) on \(publicRoute ?? route)")

        let started = Date()
        while duration <= 0 || Date().timeIntervalSince(started) < duration {
            try await tunnel.sendPing()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        await tunnel.disconnect()
        print("Serve stopped")
    }

    private static func handleForwardedMessage(
        _ message: String,
        project: BotwireProjectBundle,
        runner: BotwireRunner,
        tunnel: BotwireRelayTunnelClient
    ) async {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
              
        if object["type"] as? String == "settings_updated",
           let settingsDict = object["settings"] as? [String: Any],
           let settingsData = try? JSONSerialization.data(withJSONObject: settingsDict),
           let payload = try? JSONDecoder().decode(BotwirePersistence.BotwireSettingsSyncPayload.self, from: settingsData) {
            
            let dbPath = URL(fileURLWithPath: tunnel.config?.workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace").appendingPathComponent("appdata.oxidb")
            let oxiStore = BotwirePersistence.NativeOxiModelStore(root: dbPath)
            
            if let llms = payload.llmProfiles {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredLLMProfile.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredLLMProfile.self, id: e.id) } }
                for item in llms { try? await oxiStore.save(item) }
            }
            if let agents = payload.agentProfiles {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredAgentProfile.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredAgentProfile.self, id: e.id) } }
                for item in agents { try? await oxiStore.save(item) }
            }
            if let skills = payload.skills {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredSkill.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredSkill.self, id: e.id) } }
                for item in skills { try? await oxiStore.save(item) }
            }
            if let contexts = payload.contexts {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredContextDefinition.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredContextDefinition.self, id: e.id) } }
                for item in contexts { try? await oxiStore.save(item) }
            }
            print("relay: Applied synced settings to local OxiDB for serveProject")
            return
        }

        guard object["type"] as? String == "http_forward",
              let requestID = object["requestID"] as? String else {
            return
        }

        let method = object["method"] as? String ?? "GET"
        let path = object["path"] as? String ?? "/"
        let inputJSON = jsonString([
            "requestID": requestID,
            "method": method,
            "path": path,
            "headers": object["headers"] as? [String: Any] ?? [:],
            "query": object["query"] as? [String: Any] ?? [:],
            "body": object["body"] as? String ?? ""
        ])

        let request = BotwireRunRequest(
            objective: "Handle HTTP \(method) \(path) and return a response body.",
            inputJSON: inputJSON,
            project: project,
            workspacePath: tunnel.config?.workspacePath
        )
        let report = await runner.run(request)
        let status: Int
        let body: String
        
        if let httpResponse = report.httpResponseJSON?.jsonObject as? [String: Any] {
            status = httpResponse["status"] as? Int ?? (report.success ? 200 : 500)
            let rawBody = httpResponse["body"]
            if let strBody = rawBody as? String {
                body = strBody
            } else {
                body = jsonString(rawBody ?? [:])
            }
        } else {
            status = report.success ? 200 : 500
            body = jsonString([
                "success": report.success,
                "durationMs": report.durationMs,
                "events": report.events.map { event in
                    [
                        "kind": event.kind.rawValue,
                        "message": event.message
                    ]
                },
                "logs": report.logs,
                "result": report.result?.jsonObject ?? NSNull(),
                "error": report.errorMessage as Any
            ])
        }

        do {
            try await tunnel.sendHTTPResponse(requestID: requestID, status: status, body: body)
        } catch {
            FileHandle.standardError.writeLine("error: failed to send HTTP response for \(requestID): \(error.localizedDescription)")
        }
    }

    static func syncSettings(from object: [String: Any], config: BotwireRunnerConfig) async {
        let dbPath = URL(fileURLWithPath: config.workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace").appendingPathComponent("appdata.oxidb")
        let oxiStore = BotwirePersistence.NativeOxiModelStore(root: dbPath)
        
        let decoder = JSONDecoder()
        if let llms = object["llmProfiles"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: llms),
           let items = try? decoder.decode([BotwirePersistence.StoredLLMProfile].self, from: data) {
            let existing = try? await oxiStore.fetch(BotwirePersistence.StoredLLMProfile.self)
            if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredLLMProfile.self, id: e.id) } }
            for item in items { try? await oxiStore.save(item) }
        }
        
        if let agents = object["agentProfiles"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: agents),
           let items = try? decoder.decode([BotwirePersistence.StoredAgentProfile].self, from: data) {
            let existing = try? await oxiStore.fetch(BotwirePersistence.StoredAgentProfile.self)
            if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredAgentProfile.self, id: e.id) } }
            for item in items { try? await oxiStore.save(item) }
        }
        
        if let skills = object["appSkills"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: skills),
           let items = try? decoder.decode([BotwirePersistence.StoredSkill].self, from: data) {
            let existing = try? await oxiStore.fetch(BotwirePersistence.StoredSkill.self)
            if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredSkill.self, id: e.id) } }
            for item in items { try? await oxiStore.save(item) }
        }
        
        if let contexts = object["userContexts"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: contexts),
           let items = try? decoder.decode([BotwirePersistence.StoredContextDefinition].self, from: data) {
            let existing = try? await oxiStore.fetch(BotwirePersistence.StoredContextDefinition.self)
            if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredContextDefinition.self, id: e.id) } }
            for item in items { try? await oxiStore.save(item) }
        }
    }

    private static func handleCloudMessage(
        _ message: String,
        config: BotwireRunnerConfig,
        store: CloudResourceStore,
        tunnel: BotwireRelayTunnelClient
    ) async {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
              
        if object["type"] as? String == "settings_updated",
           let settingsDict = object["settings"] as? [String: Any],
           let settingsData = try? JSONSerialization.data(withJSONObject: settingsDict),
           let payload = try? JSONDecoder().decode(BotwirePersistence.BotwireSettingsSyncPayload.self, from: settingsData) {
            
            let dbPath = URL(fileURLWithPath: config.workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace").appendingPathComponent("appdata.oxidb")
            let oxiStore = BotwirePersistence.NativeOxiModelStore(root: dbPath)
            
            // Delete old entries and replace with new ones
            if let llms = payload.llmProfiles {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredLLMProfile.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredLLMProfile.self, id: e.id) } }
                for item in llms { try? await oxiStore.save(item) }
            }
            if let agents = payload.agentProfiles {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredAgentProfile.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredAgentProfile.self, id: e.id) } }
                for item in agents { try? await oxiStore.save(item) }
            }
            if let skills = payload.skills {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredSkill.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredSkill.self, id: e.id) } }
                for item in skills { try? await oxiStore.save(item) }
            }
            if let contexts = payload.contexts {
                let existing = try? await oxiStore.fetch(BotwirePersistence.StoredContextDefinition.self)
                if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredContextDefinition.self, id: e.id) } }
                for item in contexts { try? await oxiStore.save(item) }
            }
            print("relay: Applied synced settings to local OxiDB")
            return
        }

        guard object["type"] as? String == "brep_forward",
              let requestID = object["requestID"] as? String else {
            if object["type"] as? String == "http_forward" {
                await handleCloudHTTPForward(object, config: config, store: store, tunnel: tunnel)
            }
            return
        }

        let method = object["method"] as? String ?? "GET"
        let path = object["path"] as? String ?? "/"
        let bodyStr = object["body"] as? String ?? ""
        let bodyData = bodyStr.data(using: .utf8) ?? Data()

        if method == "GET", path == "/brep/v1/hello" {
            let sharedStartupIDs = await store.sharedStartupIDs()
            let body = jsonString([
                "peerID": config.runnerID,
                "deviceName": config.runnerName,
                "platform": "Botwire Cloud",
                "version": "1.0.0",
                "sharedStartupIDs": sharedStartupIDs
            ])
            try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
            return
        }

        if method == "POST", path == "/brep/v1/pair" {
            let body = jsonString([
                "accepted": true,
                "peerID": config.runnerID,
                "deviceName": config.runnerName,
                "platform": "Botwire Cloud",
                "authToken": ""
            ])
            try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
            return
        }

        if method == "POST", path == "/brep/v1/receive/codeblock" {
            do {
                let payload = try JSONDecoder().decode(BREPCodeBlockTransferPayload.self, from: bodyData)
                try await store.store(payload)
                emitCloudEvent("codeblock.received", [
                    "runnerID": config.runnerID,
                    "startupID": payload.startupID,
                    "algorithmID": payload.algorithmID,
                    "codeBlockID": payload.codeBlock.id,
                    "codeBlockName": payload.codeBlock.name,
                    "senderPeerID": payload.senderPeerID
                ])
                let body = jsonString([
                    "success": true,
                    "codeBlockID": payload.codeBlock.id,
                    "message": "Code block stored on Botwire Cloud."
                ])
                try await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
            } catch {
                let body = jsonString([
                    "success": false,
                    "error": error.localizedDescription
                ])
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: body)
            }
            return
        }

        if method == "POST", path == "/brep/v1/receive/algorithm" {
            do {
                guard let payloadObject = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                      let startupID = payloadObject["startupID"] as? String,
                      let startupName = payloadObject["startupName"] as? String,
                      let startupDescription = payloadObject["startupDescription"] as? String,
                      let senderPeerID = payloadObject["senderPeerID"] as? String,
                      let senderEndpoint = payloadObject["senderEndpoint"] as? String,
                      let algoSnap = payloadObject["algorithmSnapshot"] as? [String: Any],
                      let algoID = algoSnap["id"] as? String,
                      let algoName = algoSnap["name"] as? String,
                      let algoDescription = algoSnap["description"] as? String,
                      let codeblocks = algoSnap["codeblocks"] as? [[String: Any]] else {
                    throw NSError(domain: "BREP", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid payload format"])
                }

                let bundle = BotwireProjectBundle(
                    id: startupID,
                    name: startupName,
                    description: startupDescription,
                    algorithms: [
                        BotwireAlgorithm(
                            id: algoID,
                            name: algoName,
                            codeBlocks: codeblocks.compactMap(Self.portableCodeBlock(from:))
                        )
                    ],
                    metadata: [
                        "algorithm.\(algoID).description": algoDescription,
                        "algorithm.\(algoID).entryPoint": (algoSnap["entryPointRawValue"] as? String) ?? "manual",
                        "algorithm.\(algoID).httpConfig": jsonString(algoSnap["httpConfig"] as? [String: Any] ?? [:])
                    ]
                )
                var timerMetadata = bundle.metadata
                storeTimerMetadata(from: algoSnap, algorithmID: algoID, into: &timerMetadata)
                LinuxDataWatchRunner.storeDataWatchMetadata(from: algoSnap, algorithmID: algoID, into: &timerMetadata)
                let timedBundle = BotwireProjectBundle(
                    id: bundle.id,
                    name: bundle.name,
                    description: bundle.description,
                    algorithms: bundle.algorithms,
                    metadata: timerMetadata
                )
                try await store.storeProject(timedBundle)
                await store.writeDatabases(payloadObject["databases"] as? [[String: Any]] ?? [], startupID: startupID)
                await store.writeFiles(payloadObject["files"] as? [[String: Any]] ?? [], startupID: startupID)
                await store.storeSenderInfo(startupID: startupID, peerID: senderPeerID, endpoint: senderEndpoint)
                try await store.registerRoute(path: payloadObject["publicRoutePath"] as? String, startupID: startupID, algorithmID: algoID)
                if let routes = try? await store.relayRoutes() {
                    try? await tunnel.registerRoutes(routes)
                }
                
                await syncSettings(from: payloadObject, config: config)

                for block in codeblocks {
                    guard let cbID = block["id"] as? String,
                          let cbName = block["name"] as? String,
                          let cbAction = block["action"] as? String,
                          let cbRole = block["role"] as? String,
                          let codeData = block["codeData"] as? [String: Any],
                          let cbLanguage = codeData["language"] as? String,
                          let cbCode = codeData["code"] as? String else { continue }
                    
                    let desc = BREPCodeBlockDescriptor(
                        id: cbID,
                        name: cbName,
                        action: cbAction,
                        role: cbRole,
                        language: cbLanguage,
                        code: cbCode
                    )
                    
                    let cbPayload = BREPCodeBlockTransferPayload(
                        startupID: startupID,
                        startupName: startupName,
                        startupDescription: startupDescription,
                        algorithmID: algoID,
                        algorithmName: algoName,
                        algorithmDescription: algoDescription,
                        codeBlock: desc,
                        senderPeerID: senderPeerID,
                        senderEndpoint: senderEndpoint
                    )
                    try await store.store(cbPayload)
                }

                emitCloudEvent("algorithm.received", [
                    "runnerID": config.runnerID,
                    "startupID": startupID,
                    "algorithmID": algoID,
                    "algorithmName": algoName,
                    "senderPeerID": senderPeerID
                ])

                // Register resource proxy handler so this deployment can access
                // databases and resources on the source device
                registerResourceProxy(
                    startupID: startupID,
                    senderPeerID: senderPeerID,
                    tunnel: tunnel
                )

                let body = jsonString([
                    "success": true,
                    "algorithmID": algoID,
                    "message": "Algorithm stored on Botwire Cloud."
                ])
                try await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
            } catch {
                let body = jsonString([
                    "success": false,
                    "error": error.localizedDescription
                ])
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: body)
            }
            return
        }

        if method == "POST", path == "/brep/v1/receive/startup" {
            do {
                guard let object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                      let senderPeerID = object["senderPeerID"] as? String,
                      let senderEndpoint = object["senderEndpoint"] as? String,
                      let startupSnap = object["startupSnapshot"] as? [String: Any],
                      let startupID = startupSnap["id"] as? String,
                      let startupName = startupSnap["name"] as? String,
                      let startupDescription = startupSnap["description"] as? String,
                      let algorithms = startupSnap["algorithms"] as? [[String: Any]] else {
                    throw NSError(domain: "BREP", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid payload format"])
                }

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
                            id: cbID,
                            name: cbName,
                            action: cbAction,
                            role: cbRole,
                            language: cbLanguage,
                            code: cbCode
                        )
                        
                        let cbPayload = BREPCodeBlockTransferPayload(
                            startupID: startupID,
                            startupName: startupName,
                            startupDescription: startupDescription,
                            algorithmID: algoID,
                            algorithmName: algoName,
                            algorithmDescription: algoDescription,
                            codeBlock: desc,
                            senderPeerID: senderPeerID,
                            senderEndpoint: senderEndpoint
                        )
                        try await store.store(cbPayload)
                    }
                }
                let bundle = BotwireProjectBundle(
                    id: startupID,
                    name: startupName,
                    description: startupDescription,
                    algorithms: bundleAlgorithms,
                    metadata: metadata
                )
                try await store.storeProject(bundle)
                await store.writeDatabases(object["databases"] as? [[String: Any]] ?? [], startupID: startupID)
                await store.writeFiles(object["files"] as? [[String: Any]] ?? [], startupID: startupID)
                await store.storeSenderInfo(startupID: startupID, peerID: senderPeerID, endpoint: senderEndpoint)
                if let routes = try? await store.relayRoutes() {
                    try? await tunnel.registerRoutes(routes)
                }
                
                await syncSettings(from: object, config: config)

                emitCloudEvent("startup.received", [
                    "runnerID": config.runnerID,
                    "startupID": startupID,
                    "startupName": startupName,
                    "senderPeerID": senderPeerID
                ])

                // Register resource proxy handler
                registerResourceProxy(
                    startupID: startupID,
                    senderPeerID: senderPeerID,
                    tunnel: tunnel
                )

                let body = jsonString([
                    "success": true,
                    "startupID": startupID,
                    "message": "Startup stored on Botwire Cloud."
                ])
                try await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
            } catch {
                let body = jsonString([
                    "success": false,
                    "error": error.localizedDescription
                ])
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: body)
            }
            return
        }

        if method == "POST", path == "/brep/v1/execute/codeblock" {
            do {
                let request = try JSONDecoder().decode(BREPExecuteRequest.self, from: bodyData)
                emitCloudEvent("codeblock.execute.started", [
                    "runnerID": config.runnerID,
                    "startupID": request.startupID,
                    "algorithmID": request.algorithmID,
                    "codeBlockID": request.codeBlockID,
                    "callerPeerID": request.callerPeerID
                ])
                guard let stored = try await store.codeBlock(id: request.codeBlockID) else {
                    let result = CloudExecutionResultFactory.failure(
                        algorithmID: request.algorithmID,
                        codeBlockID: request.codeBlockID,
                        codeBlockName: request.codeBlockID,
                        message: "Code block is not deployed to this Botwire Cloud worker."
                    )
                    try await tunnel.sendBREPResponse(
                        requestID: requestID,
                        status: 404,
                        body: encodedJSONString(result)
                    )
                    return
                }
                let result = await CloudExecutionResultFactory.execute(stored: stored, request: request, traceStore: store)
                emitCloudEvent("codeblock.execute.finished", [
                    "runnerID": config.runnerID,
                    "startupID": request.startupID,
                    "algorithmID": request.algorithmID,
                    "codeBlockID": request.codeBlockID,
                    "success": result.success,
                    "durationMs": Int(result.finishedAt.timeIntervalSince(result.startedAt) * 1000)
                ])
                try await tunnel.sendBREPResponse(
                    requestID: requestID,
                    status: result.success ? 200 : 500,
                    body: encodedJSONString(result)
                )
            } catch {
                let result = CloudExecutionResultFactory.failure(
                    algorithmID: "00000000-0000-0000-0000-000000000000",
                    codeBlockID: "unknown",
                    codeBlockName: "Remote Code Block",
                    message: error.localizedDescription
                )
                try? await tunnel.sendBREPResponse(
                    requestID: requestID,
                    status: 400,
                    body: encodedJSONString(result)
                )
            }
            return
        }

        if method == "POST", path == "/brep/v1/return/codeblock" {
            if let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let codeBlockID = object["codeBlockID"] as? String {
                // Read the codeblock state before deleting it
                let storedBlock = try? await store.codeBlock(id: codeBlockID)
                var responseDict: [String: Any] = [
                    "success": true,
                    "codeBlockID": codeBlockID
                ]
                if let storedBlock {
                    responseDict["codeBlock"] = [
                        "id": storedBlock.codeBlock.id,
                        "name": storedBlock.codeBlock.name,
                        "action": storedBlock.codeBlock.action,
                        "role": storedBlock.codeBlock.role,
                        "language": storedBlock.codeBlock.language,
                        "code": storedBlock.codeBlock.code
                    ]
                }
                // Send response FIRST — only delete after response is sent
                let body = jsonString(responseDict)
                do {
                    try await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
                } catch {
                    FileHandle.standardError.writeLine("error: [BREP Return/codeblock] Failed to send response: \(error.localizedDescription)")
                }
                // Now safe to delete
                await store.remove(codeBlockID: codeBlockID)
                emitCloudEvent("codeblock.returned", [
                    "runnerID": config.runnerID,
                    "codeBlockID": codeBlockID
                ])
            } else {
                let body = jsonString([
                    "success": false,
                    "error": "Missing codeBlockID."
                ])
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: body)
            }
            return
        }

        if method == "POST", path == "/brep/v1/return/algorithm" {
            if let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let startupID = object["startupID"] as? String,
               let algorithmID = object["algorithmID"] as? String {

                // Read the algorithm state before deleting
                var algorithmSnapshot: [String: Any]? = nil
                if let bundle = try? await store.project(startupID: startupID),
                   let algorithm = bundle.algorithms.first(where: { $0.id == algorithmID }) {
                    algorithmSnapshot = linuxReturnedAlgorithmSnapshot(for: algorithm, in: bundle)
                }

                try? await store.removeAlgorithm(startupID: startupID, algorithmID: algorithmID)
                if let routes = try? await store.relayRoutes() {
                    try? await tunnel.registerRoutes(routes)
                }
                emitCloudEvent("algorithm.returned", [
                    "runnerID": config.runnerID,
                    "startupID": startupID,
                    "algorithmID": algorithmID
                ])
                var responseDict: [String: Any] = ["success": true, "algorithmID": algorithmID]
                if let algorithmSnapshot {
                    responseDict["algorithmSnapshot"] = algorithmSnapshot
                }
                
                if let databases = try? await store.readAllDatabases(startupID: startupID) {
                    // Filter to only return algorithm-scoped databases if possible,
                    // but since readAllDatabases currently grabs everything in OxiDB for the startup,
                    // WorkspaceMainView will overwrite the exact databases returned.
                    // This is safe because files/dbs are diffed anyway!
                    responseDict["databases"] = databases
                }
                
                if let files = try? await store.readAllFiles(startupID: startupID) {
                    responseDict["files"] = files
                }
                
                // Now that we've read them, we can safely delete the algorithm databases from disk!
                if let databaseIDs = object["databaseIDs"] as? [String] {
                    for dbID in databaseIDs {
                        try? await store.removeDatabase(startupID: startupID, databaseID: dbID)
                    }
                }
                
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: jsonString(responseDict))
            } else {
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: jsonString(["success": false, "error": "Missing startupID or algorithmID."]))
            }
            return
        }

        if method == "POST", path == "/brep/v1/return/startup" {
            if let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let startupID = object["startupID"] as? String {

                // Read the project bundle before deleting
                var startupSnapshot: [String: Any]? = nil
                if let bundle = try? await store.project(startupID: startupID) {
                    startupSnapshot = linuxReturnedStartupSnapshot(from: bundle)
                }

                var responseDict: [String: Any] = ["success": true, "startupID": startupID]
                if let startupSnapshot {
                    responseDict["startupSnapshot"] = startupSnapshot
                }
                
                if let databases = try? await store.readAllDatabases(startupID: startupID) {
                    responseDict["databases"] = databases
                }
                if let files = try? await store.readAllFiles(startupID: startupID) {
                    responseDict["files"] = files
                }
                
                // Send response FIRST — only delete after response is confirmed sent
                do {
                    try await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: jsonString(responseDict))
                } catch {
                    FileHandle.standardError.writeLine("error: [BREP Return/startup] Failed to send response: \(error.localizedDescription)")
                }

                // Now safe to delete from local store
                try? await store.removeStartup(startupID: startupID)
                ResourceProxyRegistry.shared.unregister(projectId: startupID)
                if let routes = try? await store.relayRoutes() {
                    try? await tunnel.registerRoutes(routes)
                }
                emitCloudEvent("startup.returned", [
                    "runnerID": config.runnerID,
                    "startupID": startupID
                ])
            } else {
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: jsonString(["success": false, "error": "Missing startupID."]))
            }
            return
        }
        // Proxied HTTP execution from the deploying device (Option A proxy)
        if method == "POST", path == "/brep/v1/execute/http" {
            do {
                guard let object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                    throw NSError(domain: "BREP", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
                }
                // Reuse the existing HTTP forward handler with the requestID from the BREP envelope
                var httpObject = object
                httpObject["requestID"] = requestID
                // Route via the existing handleCloudHTTPForward which already handles route lookup + execution
                await handleCloudHTTPForward(httpObject, config: config, store: store, tunnel: tunnel)
            } catch {
                let body = jsonString(["success": false, "error": error.localizedDescription])
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: body)
            }
            return
        }

        // Remote pause/activate control from the deploying device
        if method == "POST", path == "/brep/v1/control/state" {
            guard let request = BREPControlStateRequest.decode(jsonData: bodyData) else {
                try? await tunnel.sendBREPResponse(
                    requestID: requestID,
                    status: 400,
                    body: BREPControlStateResponse(success: false, error: "Missing startupID.").jsonString()
                )
                return
            }

            if let isActive = request.isActive {
                await store.setStartupActive(startupID: request.startupID, isActive: isActive)
                emitCloudEvent("startup.state.changed", [
                    "runnerID": config.runnerID,
                    "startupID": request.startupID,
                    "isActive": isActive
                ])
                let body = BREPControlStateResponse(success: true, startupID: request.startupID, isActive: isActive).jsonString()
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
            } else {
                let isActive = await store.isStartupActive(startupID: request.startupID)
                let body = BREPControlStateResponse(success: true, startupID: request.startupID, isActive: isActive).jsonString()
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
            }
            return
        }

        // Remote performance trace retrieval
        if method == "POST", path == "/brep/v1/control/getPerformanceTraces" {
            if let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let startupID = object["startupID"] as? String {
                let limit = (object["limit"] as? Int) ?? 50
                let traces = await store.fetchTraces(startupID: startupID, limit: limit)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(traces),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: jsonStr)
                } else {
                    try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: "[]")
                }
            } else {
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: jsonString(["success": false, "error": "Missing startupID."]))
            }
            return
        }

        // Remote performance profiling on/off control
        if method == "POST", path == "/brep/v1/control/setPerformanceProfiling" {
            if let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let startupID = object["startupID"] as? String {
                if let enabled = object["enabled"] as? Bool {
                    await store.setPerformanceProfiling(startupID: startupID, enabled: enabled)
                    let body = jsonString(["success": true, "startupID": startupID, "enabled": enabled])
                    try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
                } else {
                    // Query mode — return current state
                    let enabled = await store.isProfilingEnabled(startupID: startupID)
                    let body = jsonString(["success": true, "startupID": startupID, "enabled": enabled])
                    try? await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: body)
                }
            } else {
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: jsonString(["success": false, "error": "Missing startupID."]))
            }
            return
        }

        // ── Runtime Bus: Unified message endpoint ──────────────────────────
        if method == "POST", path == "/bus/v1/message" {
            do {
                let busMessage = try JSONDecoder().decode(LinuxBusMessage.self, from: bodyData)
                let response = await handleBusMessage(busMessage, config: config, store: store, tunnel: tunnel)
                let responseData = try JSONEncoder().encode(response)
                let responseStr = String(data: responseData, encoding: .utf8) ?? "{}"
                try await tunnel.sendBREPResponse(requestID: requestID, status: 200, body: responseStr)
            } catch {
                let errorResponse = LinuxBusResponse(
                    messageID: "unknown",
                    success: false,
                    payload: nil,
                    error: error.localizedDescription
                )
                let responseStr = (try? JSONEncoder().encode(errorResponse))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try? await tunnel.sendBREPResponse(requestID: requestID, status: 400, body: responseStr)
            }
            return
        }

        let body = jsonString([
            "error": "Botwire Cloud worker does not handle \(method) \(path) yet."
        ])
        try? await tunnel.sendBREPResponse(requestID: requestID, status: 404, body: body)
    }

    private static func normalizedRoute(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    static func portableCodeBlock(from block: [String: Any]) -> BotwireCodeBlock? {
        guard let cbID = block["id"] as? String,
              let cbName = block["name"] as? String,
              let codeData = block["codeData"] as? [String: Any],
              let cbLanguage = codeData["language"] as? String,
              let cbCode = codeData["code"] as? String else {
            return nil
        }
        let roleRaw = block["role"] as? String ?? "logic"
        return BotwireCodeBlock(
            id: cbID,
            name: cbName,
            role: BotwireCodeBlock.Role(rawValue: roleRaw) ?? .logic,
            language: cbLanguage,
            source: cbCode
        )
    }

    private static func handleCloudHTTPForward(
        _ object: [String: Any],
        config: BotwireRunnerConfig,
        store: CloudResourceStore,
        tunnel: BotwireRelayTunnelClient
    ) async {
        guard let requestID = object["requestID"] as? String else { return }
        let path = object["path"] as? String ?? "/"
        do {
            guard let route = try await store.routeTarget(path: path),
                  let bundle = try await store.project(startupID: route.startupID),
                  let algorithm = bundle.algorithms.first(where: { $0.id == route.algorithmID }),
                  let codeBlock = algorithm.codeBlocks.first(where: { $0.role == .logic }) else {
                try? await tunnel.sendHTTPResponse(
                    requestID: requestID,
                    status: 404,
                    body: jsonString(["error": "Route not found on Botwire Cloud runner."])
                )
                return
            }

            // Check active/paused state
            if await !store.isStartupActive(startupID: route.startupID) {
                try? await tunnel.sendHTTPResponse(
                    requestID: requestID,
                    status: 503,
                    body: jsonString(["error": "Project paused", "message": "This project is currently paused."])
                )
                return
            }

            let method = object["method"] as? String ?? "GET"
            let headers = object["headers"] as? [String: Any] ?? [:]
            let triggerConfig = httpConfig(for: route.algorithmID, in: bundle)
            let corsHeaders = corsHeaders(config: triggerConfig, requestHeaders: headers)
            let assetPrefix = route.path + "/assets/"
            if path.hasPrefix(assetPrefix) {
                let assetPath = String(path.dropFirst(assetPrefix.count))
                if let publicFile = await store.publicFile(startupID: route.startupID, relativePath: assetPath) {
                    try? await tunnel.sendHTTPResponse(
                        requestID: requestID,
                        status: 200,
                        headers: ["content-type": publicFile.mimeType, "Cache-Control": "public, max-age=300"].merging(corsHeaders) { lhs, _ in lhs },
                        body: String(data: publicFile.data, encoding: .utf8) ?? publicFile.data.base64EncodedString()
                    )
                } else {
                    try? await tunnel.sendHTTPResponse(
                        requestID: requestID,
                        status: 404,
                        headers: ["content-type": "application/json"].merging(corsHeaders) { lhs, _ in lhs },
                        body: jsonString(["error": "Public file not found"])
                    )
                }
                return
            }

            if method.uppercased() == "OPTIONS" {
                try? await tunnel.sendHTTPResponse(requestID: requestID, status: 204, headers: corsHeaders, body: "")
                return
            }
            if let rejection = rejectHTTPRequest(config: triggerConfig, method: method, headers: headers) {
                try? await tunnel.sendHTTPResponse(
                    requestID: requestID,
                    status: rejection.status,
                    headers: rejection.headers.merging(corsHeaders) { lhs, _ in lhs },
                    body: rejection.body
                )
                return
            }

            let inputJSON = jsonString([
                "requestID": requestID,
                "method": method,
                "path": path,
                "headers": headers,
                "query": object["query"] as? [String: Any] ?? [:],
                "body": object["body"] as? String ?? ""
            ])
            let result = await CloudExecutionResultFactory.executeCodeBlock(
                startupID: route.startupID,
                algorithmID: route.algorithmID,
                codeBlock: codeBlock,
                inputJSON: inputJSON,
                workspacePath: config.workspacePath,
                runID: requestID,
                trigger: "http",
                traceStore: store
            )

            let response = httpResponsePayload(from: result)
            try? await tunnel.sendHTTPResponse(requestID: requestID, status: response.status, headers: ["content-type": "application/json"].merging(corsHeaders) { lhs, _ in lhs }, body: response.body)
        } catch {
            try? await tunnel.sendHTTPResponse(
                requestID: requestID,
                status: 500,
                body: jsonString(["error": error.localizedDescription])
            )
        }
    }

    private static func httpResponsePayload(from result: CloudAlgorithmExecutionResult) -> (status: Int, body: String) {
        if let httpResponseJSON = result.httpResponseJSON,
           let data = httpResponseJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = object["status"] as? Int
                ?? object["statusCode"] as? Int
                ?? (result.success ? 200 : 500)
            let rawBody = object["body"]
            if let body = rawBody as? String {
                return (status, body)
            }
            return (status, jsonString(rawBody ?? [:]))
        }

        return (
            result.success ? 200 : 500,
            result.outputJSON ?? encodedJSONString(result)
        )
    }

    private static func httpConfig(for algorithmID: String, in bundle: BotwireProjectBundle) -> [String: Any] {
        guard let json = bundle.metadata["algorithm.\(algorithmID).httpConfig"],
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func corsHeaders(config: [String: Any], requestHeaders: [String: Any]) -> [String: String] {
        guard let cors = config["cors"] as? [String: Any],
              (cors["enabled"] as? Bool) == true else {
            return [:]
        }
        let origins = cors["allowedOrigins"] as? [String] ?? []
        let origin = (requestHeaders.first { $0.key.lowercased() == "origin" }?.value as? String) ?? ""
        let allowOrigin = origins.contains("*") ? "*" : (origins.contains(origin) ? origin : (origins.first ?? "null"))
        return [
            "Access-Control-Allow-Origin": allowOrigin,
            "Access-Control-Allow-Methods": ((cors["allowedMethods"] as? [String]) ?? ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]).joined(separator: ", "),
            "Access-Control-Allow-Headers": ((cors["allowedHeaders"] as? [String]) ?? ["Content-Type", "Authorization", "X-Botwire-Requester", "X-Botwire-Grant-Request", "X-Botwire-Grant-Duration"]).joined(separator: ", "),
            "Vary": "Origin"
        ]
    }

    private static func rejectHTTPRequest(config: [String: Any], method: String, headers: [String: Any]) -> (status: Int, headers: [String: String], body: String)? {
        let expectedMethod = (config["method"] as? String ?? "*").uppercased()
        if expectedMethod != "*" && expectedMethod != method.uppercased() {
            return (405, ["content-type": "application/json"], jsonString(["error": "Method not allowed. Expected \(expectedMethod)."]))
        }
        guard (config["authMode"] as? String) == "bearer" else { return nil }
        let auth = (headers.first { $0.key.lowercased() == "authorization" }?.value as? String) ?? ""
        let prefix = "Bearer "
        guard auth.hasPrefix(prefix) else {
            return (401, ["content-type": "application/json", "WWW-Authenticate": "Bearer"], jsonString(["error": "Unauthorized"]))
        }
        let token = String(auth.dropFirst(prefix.count))
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        guard hash == (config["bearerTokenHash"] as? String) else {
            return (401, ["content-type": "application/json", "WWW-Authenticate": "Bearer"], jsonString(["error": "Unauthorized"]))
        }
        return nil
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func emitCloudEvent(_ kind: String, _ fields: [String: Any]) {
        var payload = fields
        payload["kind"] = kind
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        print("BW_EVENT \(jsonString(payload))")
    }

    /// Register a resource proxy handler for a deployed startup.
    /// When JS code accesses a resource that doesn't exist locally,
    /// this handler forwards the request to the source device via BREP.
    static func registerResourceProxy(
        startupID: String,
        senderPeerID: String,
        tunnel: BotwireRelayTunnelClient
    ) {
        ResourceProxyRegistry.shared.register(projectId: startupID) { request in
            guard let requestData = try? JSONSerialization.data(withJSONObject: request),
                  let requestBody = String(data: requestData, encoding: .utf8) else {
                return nil
            }

            print("🔀 [ResourceProxy] Forwarding \(request["resourceType"] as? String ?? "unknown") request for project \(startupID.prefix(8)) to peer \(senderPeerID.prefix(8))")

            let response = tunnel.forwardBREPSync(
                targetPeerID: senderPeerID,
                method: "POST",
                path: "/brep/v1/proxy/resource",
                body: requestBody
            )

            if let response {
                print("🔀 [ResourceProxy] Got response from source device (\(response.count) bytes)")
            } else {
                print("🔀 [ResourceProxy] No response from source device (timeout or error)")
            }

            return response
        }
    }

    private static func encodedJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func fetchSettings(config: BotwireRunnerConfig) async {
        guard let token = config.sessionToken else { return }
        let urlStr = "\(config.relayBaseURL.absoluteString)/api/v1/settings"
        guard let url = URL(string: urlStr) else { return }
        
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let settingsDict = json["settings"] as? [String: Any],
               let settingsData = try? JSONSerialization.data(withJSONObject: settingsDict),
               let payload = try? JSONDecoder().decode(BotwirePersistence.BotwireSettingsSyncPayload.self, from: settingsData) {
                
                let dbPath = URL(fileURLWithPath: config.workspacePath ?? "/var/lib/botwire-cloud/users/default/workspace").appendingPathComponent("appdata.oxidb")
                let oxiStore = BotwirePersistence.NativeOxiModelStore(root: dbPath)
                
                if let llms = payload.llmProfiles {
                    let existing = try? await oxiStore.fetch(BotwirePersistence.StoredLLMProfile.self)
                    if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredLLMProfile.self, id: e.id) } }
                    for item in llms { try? await oxiStore.save(item) }
                }
                if let agents = payload.agentProfiles {
                    let existing = try? await oxiStore.fetch(BotwirePersistence.StoredAgentProfile.self)
                    if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredAgentProfile.self, id: e.id) } }
                    for item in agents { try? await oxiStore.save(item) }
                }
                if let skills = payload.skills {
                    let existing = try? await oxiStore.fetch(BotwirePersistence.StoredSkill.self)
                    if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredSkill.self, id: e.id) } }
                    for item in skills { try? await oxiStore.save(item) }
                }
                if let contexts = payload.contexts {
                    let existing = try? await oxiStore.fetch(BotwirePersistence.StoredContextDefinition.self)
                    if let existing { for e in existing { try? await oxiStore.delete(BotwirePersistence.StoredContextDefinition.self, id: e.id) } }
                    for item in contexts { try? await oxiStore.save(item) }
                }
                print("relay: Fetched and applied initial sync settings")
            }
        } catch {
            print("relay: Failed to fetch initial settings - \(error.localizedDescription)")
        }
    }
}

private extension JSONValue {
    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.jsonObject }
        case .array(let value):
            return value.map { $0.jsonObject }
        case .null:
            return NSNull()
        }
    }
}

private struct CLIOptions {
    private var values: [String: String] = [:]

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let item = arguments[index]
            guard item.hasPrefix("--") else {
                index += 1
                continue
            }
            let key = String(item.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                values[key] = "true"
                index += 1
            }
        }
    }

    func string(_ key: String) -> String? {
        values[key]
    }

    func url(_ key: String, default defaultURL: URL) -> URL {
        guard let raw = values[key], let url = URL(string: raw) else {
            return defaultURL
        }
        return url
    }
}

private enum CLIError: LocalizedError {
    case unknownCommand(String)
    case missingOption(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .missingOption(let option):
            return "Missing required option: --\(option)"
        }
    }
}

private extension FileHandle {
    func writeLine(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            write(data)
        }
    }
}
