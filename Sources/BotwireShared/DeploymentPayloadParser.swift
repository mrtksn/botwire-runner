//
//  DeploymentPayloadParser.swift
//  BotwireShared
//
//  Canonical parser for incoming BREP deployment payloads.
//  Shared across iOS, Android, and Linux to ensure identical
//  interpretation of deployment data.
//
//  This eliminates the class of bugs where each platform
//  reimplements parsing with subtly different field names
//  or enum mappings.
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Result of parsing a startup deployment payload.
public struct ParsedStartupDeployment: Sendable {
    public let startupID: String
    public let startupName: String
    public let startupDescription: String
    public let algorithms: [ParsedAlgorithmDeployment]
    /// Raw JSON data preserved for platform-specific processing
    /// (e.g. codeblock execution, database imports)
    public let rawPayloadJSON: String

    public init(startupID: String, startupName: String, startupDescription: String, algorithms: [ParsedAlgorithmDeployment], rawPayloadJSON: String) {
        self.startupID = startupID
        self.startupName = startupName
        self.startupDescription = startupDescription
        self.algorithms = algorithms
        self.rawPayloadJSON = rawPayloadJSON
    }
}

/// Result of parsing a single algorithm from a deployment payload.
public struct ParsedAlgorithmDeployment: Sendable {
    public let id: String
    public let name: String
    public let entryPoint: AlgorithmEntryPointKind
    public let route: String?
    public let codeBlockCount: Int
    public let concatenatedCode: String

    public init(id: String, name: String, entryPoint: AlgorithmEntryPointKind, route: String?, codeBlockCount: Int, concatenatedCode: String) {
        self.id = id
        self.name = name
        self.entryPoint = entryPoint
        self.route = route
        self.codeBlockCount = codeBlockCount
        self.concatenatedCode = concatenatedCode
    }
}

/// Internal structures for parsing JSON
private struct IncomingPayload: Codable {
    struct Snapshot: Codable {
        let id: String?
        let name: String?
        let description: String?
        let algorithms: [Algorithm]?
    }
    struct Algorithm: Codable {
        let id: String?
        let name: String?
        let entryPointRawValue: String?
        let httpConfig: HTTPConfig?
        let codeblocks: [CodeBlock]?
    }
    struct HTTPConfig: Codable {
        let path: String?
    }
    struct CodeBlock: Codable {
        let name: String?
        let codeData: CodeData?
        let code: String?
    }
    struct CodeData: Codable {
        let code: String?
    }
    let startupSnapshot: Snapshot?
    let publicRoutePaths: [String: String]?
    
    // For single algorithm deployment
    let startupID: String?
    let publicRoutePath: String?
    let algorithmSnapshot: Algorithm?
}

/// Canonical deployment payload parser.
public enum DeploymentPayloadParser {

    // MARK: - Startup Deployment

    public static func parseStartupDeployment(jsonString: String) -> ParsedStartupDeployment? {
        guard let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IncomingPayload.self, from: data),
              let snapshot = payload.startupSnapshot else {
            return nil
        }

        let startupID = snapshot.id ?? UUID().uuidString
        let startupName = snapshot.name ?? "Imported Project"
        let startupDescription = snapshot.description ?? ""
        let publicRoutePaths = payload.publicRoutePaths ?? [:]

        var algorithms: [ParsedAlgorithmDeployment] = []
        if let algos = snapshot.algorithms {
            for algo in algos {
                let parsed = parseAlgorithmFromSnapshot(
                    algo,
                    publicRoutePath: nil,
                    publicRoutePaths: publicRoutePaths
                )
                algorithms.append(parsed)
            }
        }

        return ParsedStartupDeployment(
            startupID: startupID,
            startupName: startupName,
            startupDescription: startupDescription,
            algorithms: algorithms,
            rawPayloadJSON: jsonString
        )
    }

    // MARK: - Single Algorithm Deployment

    public static func parseAlgorithmDeployment(jsonString: String) -> (startupID: String, algorithm: ParsedAlgorithmDeployment)? {
        guard let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IncomingPayload.self, from: data),
              let algoSnapshot = payload.algorithmSnapshot else {
            return nil
        }

        let startupID = payload.startupID ?? ""
        let publicRoutePath = payload.publicRoutePath

        let parsed = parseAlgorithmFromSnapshot(
            algoSnapshot,
            publicRoutePath: publicRoutePath,
            publicRoutePaths: nil
        )

        return (startupID: startupID, algorithm: parsed)
    }

    // MARK: - Internal

    private static func parseAlgorithmFromSnapshot(
        _ algo: IncomingPayload.Algorithm,
        publicRoutePath: String?,
        publicRoutePaths: [String: String]?
    ) -> ParsedAlgorithmDeployment {
        let algoID = algo.id ?? UUID().uuidString
        let algoName = algo.name ?? "Algorithm"

        let entryPointRaw = algo.entryPointRawValue ?? "manual"
        let entryPoint = normalizeEntryPoint(entryPointRaw)

        let route: String? = {
            if let paths = publicRoutePaths, let path = paths[algoID], !path.isEmpty {
                return path
            }
            if let path = publicRoutePath, !path.isEmpty {
                return path
            }
            if let path = algo.httpConfig?.path, !path.isEmpty {
                return path
            }
            return nil
        }()

        var codeBuilder = ""
        var codeBlockCount = 0
        if let codeblocks = algo.codeblocks {
            for cb in codeblocks {
                let blockName = cb.name ?? "block \(codeBlockCount)"
                let code: String
                if let c = cb.codeData?.code, !c.isEmpty {
                    code = c
                } else if let c = cb.code, !c.isEmpty {
                    code = c
                } else {
                    continue
                }

                codeBuilder += "// --- \(blockName) ---\n"
                codeBuilder += code + "\n"
                codeBlockCount += 1
            }
        }

        return ParsedAlgorithmDeployment(
            id: algoID,
            name: algoName,
            entryPoint: entryPoint,
            route: route,
            codeBlockCount: codeBlockCount,
            concatenatedCode: codeBuilder
        )
    }

    private static func normalizeEntryPoint(_ rawValue: String) -> AlgorithmEntryPointKind {
        switch rawValue {
        case "httpTrigger", "http":
            return .http
        case "timer":
            return .timer
        case "dataWatch":
            return .dataWatch
        default:
            return .manual
        }
    }

    // MARK: - Route Collection

    public static func collectRoutes(from projects: [DeployedProjectDescriptor]) -> [RouteDescriptor] {
        var routes: [RouteDescriptor] = []
        for project in projects where project.isActive {
            for algo in project.algorithms where algo.entryPoint == .http {
                guard let route = algo.route, !route.isEmpty else { continue }
                routes.append(RouteDescriptor(
                    path: route,
                    startupID: project.id,
                    algorithmID: algo.id
                ))
            }
        }
        return routes
    }
}

/// A route descriptor ready for relay registration.
public struct RouteDescriptor: Codable, Sendable {
    public let path: String
    public let startupID: String
    public let algorithmID: String

    public init(path: String, startupID: String, algorithmID: String) {
        self.path = path
        self.startupID = startupID
        self.algorithmID = algorithmID
    }

    /// Convert to the dictionary format expected by the relay.
    public func toRelayDict() -> [String: String] {
        return [
            "path": path,
            "startupID": startupID,
            "algorithmID": algorithmID
        ]
    }
}
