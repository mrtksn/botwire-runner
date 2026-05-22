import Foundation

/// Global registry for resource proxy handlers, keyed by projectId (startupID).
/// When a LinuxJSHostBridge can't find a resource locally, it checks this registry
/// for a handler that can forward the request to the source device via BREP.
public final class ResourceProxyRegistry: @unchecked Sendable {
    public static let shared = ResourceProxyRegistry()
    private var handlers: [String: ([String: Any]) -> String?] = [:]
    private let lock = NSLock()

    /// Register a proxy handler for a given startup/project ID.
    public func register(projectId: String, handler: @escaping ([String: Any]) -> String?) {
        lock.lock()
        handlers[projectId] = handler
        lock.unlock()
        print("🔀 [ResourceProxy] Registered proxy handler for project \(projectId.prefix(8))")
    }

    /// Remove a proxy handler (e.g., on recall).
    public func unregister(projectId: String) {
        lock.lock()
        handlers.removeValue(forKey: projectId)
        lock.unlock()
    }

    /// Get the proxy handler for a project, if registered.
    public func handler(for projectId: String) -> (([String: Any]) -> String?)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[projectId]
    }
}
