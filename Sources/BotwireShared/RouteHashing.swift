//
//  RouteHashing.swift
//  BotwireShared
//
//  Route hash generation for HTTP-triggered algorithms.
//  This MUST produce identical hashes on iOS, Android, and Linux.
//
//  The route hash is: first 12 hex characters of SHA256(startupID + algorithmID + salt)
//  Example: "773a836fa825"
//

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Route hashing utilities shared across all platforms.
public enum BotwireRouteHashing {

    /// Global salt for route hash generation.
    /// ⚠️  Changing this invalidates all existing routes across all platforms.
    public static let salt = "bw_http_rt_v1"

    /// Generate a deterministic, URL-safe route hash for an algorithm's HTTP endpoint.
    ///
    /// - Parameters:
    ///   - startupID: The project/startup UUID string
    ///   - algorithmID: The algorithm UUID string
    ///   - salt: Hash salt (defaults to the global Botwire salt)
    /// - Returns: A 12-character hex string, e.g. "773a836fa825"
    public static func routeHash(startupID: String, algorithmID: String, salt: String = BotwireRouteHashing.salt) -> String {
        let input = startupID + algorithmID + salt
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    /// Generate the public path (with leading slash) for relay route registration.
    ///
    /// - Parameters:
    ///   - startupID: The project/startup UUID string
    ///   - algorithmID: The algorithm UUID string
    /// - Returns: e.g. "/773a836fa825"
    public static func publicPath(startupID: String, algorithmID: String) -> String {
        return "/\(routeHash(startupID: startupID, algorithmID: algorithmID))"
    }
}
