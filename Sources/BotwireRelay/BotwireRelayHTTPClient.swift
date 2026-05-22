import BotwireCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BotwireRelayClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Relay returned an invalid response."
        case .httpStatus(let status, let body):
            return "Relay returned HTTP \(status): \(body)"
        }
    }
}

public struct BotwireRelayHTTPClient: Sendable {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL = URL(string: "https://algo.botwire.app")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func health() async throws -> [String: JSONValue] {
        try await getObject(path: "/health")
    }

    public func status() async throws -> RelayStatus {
        let object = try await getObject(path: "/api/v1/status")
        return RelayStatus(
            version: object.string("version"),
            connectedDevices: object.int("connectedDevices"),
            pendingRequests: object.int("pendingRequests"),
            raw: object
        )
    }

    public func registerDevRunner(
        runnerID: String,
        runnerName: String,
        platform: String = "linux",
        devToken: String
    ) async throws -> RunnerRegistrationResponse {
        let body = RunnerRegistrationRequest(
            peerID: runnerID,
            deviceName: runnerName,
            platform: platform
        )
        return try await post(
            path: "/api/v1/dev/runner/register",
            body: body,
            headers: ["x-dev-runner-token": devToken]
        )
    }

    public func claimRunnerPairingToken(
        token: String,
        runnerID: String,
        runnerName: String,
        platform: String = "linux"
    ) async throws -> RunnerPairingClaimResponse {
        let body = RunnerPairingClaimRequest(
            token: token,
            runnerID: runnerID,
            runnerName: runnerName,
            platform: platform
        )
        return try await post(path: "/api/v1/runner-pairing/claim", body: body)
    }

    private func getObject(path: String) async throws -> [String: JSONValue] {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BotwireRelayClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BotwireRelayClientError.httpStatus(httpResponse.statusCode, body)
        }

        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BotwireRelayClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BotwireRelayClientError.httpStatus(httpResponse.statusCode, body)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

public struct RunnerRegistrationRequest: Codable, Sendable {
    public var peerID: String
    public var deviceName: String
    public var platform: String
}

public struct RunnerRegistrationResponse: Codable, Sendable {
    public var success: Bool
    public var shareableID: String
    public var relayAuthToken: String
    public var sessionToken: String
    public var userID: String
}

public struct RunnerPairingClaimRequest: Codable, Sendable {
    public var token: String
    public var runnerID: String
    public var runnerName: String
    public var platform: String
}

public struct RunnerPairingClaimResponse: Codable, Sendable {
    public var success: Bool
    public var peerID: String
    public var runnerID: String
    public var runnerName: String
    public var platform: String
    public var shareableID: String
    public var relayAuthToken: String
    public var sessionToken: String
    public var relayBaseURL: URL
    public var tunnelURL: URL
    public var userID: String
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .number(let value) = self[key] else { return nil }
        return Int(value)
    }
}
