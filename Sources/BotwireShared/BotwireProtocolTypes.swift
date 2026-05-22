//
//  BotwireProtocolTypes.swift
//  BotwireShared
//
//  Cross-platform protocol types shared between iOS, Android, and Linux.
//  These types define the canonical wire format for Botwire's BREP protocol.
//
//  ⚠️  SINGLE SOURCE OF TRUTH: Any change here is automatically reflected
//  on all platforms. Never redefine these types in Kotlin or elsewhere.
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Algorithm Entry Point

/// Defines how an algorithm is triggered.
/// This enum's raw values are used on the wire (JSON) and must never change.
public enum AlgorithmEntryPointKind: String, Codable, CaseIterable, Sendable {
    case manual
    case http
    case timer
    case dataWatch
}

// MARK: - Relay Message Types

/// All WebSocket message types exchanged with the Botwire relay server.
public enum RelayMessageType: String, Codable, Sendable {
    case auth
    case authOK = "auth_ok"
    case authError = "auth_error"
    case registerRoutes = "register_routes"
    case routesRegistered = "routes_registered"
    case httpForward = "http_forward"
    case httpResponse = "http_response"
    case brepForward = "brep_forward"
    case brepResponse = "brep_response"
    case ping
    case pong
    case error
}

// MARK: - BREP Payload Models

/// Peer identity on the Botwire network.
public struct BREPPeerIdentity: Codable, Sendable {
    public let peerID: String
    public let deviceName: String
    public let platform: String
    public let shareableID: String?

    public init(peerID: String, deviceName: String, platform: String, shareableID: String? = nil) {
        self.peerID = peerID
        self.deviceName = deviceName
        self.platform = platform
        self.shareableID = shareableID
    }
}

/// A lightweight algorithm descriptor for deployment tracking.
/// This is what gets stored in the project registry after deployment.
public struct DeployedAlgorithmDescriptor: Codable, Sendable {
    public let id: String
    public let name: String
    public let entryPoint: AlgorithmEntryPointKind
    public let route: String?
    public let codeBlockCount: Int

    public init(id: String, name: String, entryPoint: AlgorithmEntryPointKind, route: String? = nil, codeBlockCount: Int = 0) {
        self.id = id
        self.name = name
        self.entryPoint = entryPoint
        self.route = route
        self.codeBlockCount = codeBlockCount
    }
}

/// A lightweight project descriptor for deployment tracking.
public struct DeployedProjectDescriptor: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let isActive: Bool
    public let algorithms: [DeployedAlgorithmDescriptor]

    public init(id: String, name: String, description: String = "", isActive: Bool = true, algorithms: [DeployedAlgorithmDescriptor] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.isActive = isActive
        self.algorithms = algorithms
    }
}

// MARK: - HTTP Trigger Configuration

/// HTTP trigger authentication mode.
public enum HTTPTriggerAuthMode: String, Codable, CaseIterable, Sendable {
    case none
    case bearer
}

/// Relay connection state, observed by the UI layer.
public enum RelayConnectionState: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case error
}
