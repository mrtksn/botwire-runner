import Foundation
import OxiDB

public final class OxiDBEmbeddedStore {
    private let root: URL
    private var database: OxiDBDatabase?

    public init(root: URL) {
        self.root = root
    }

    deinit {
        close()
    }

    public func open() throws -> OxiDBDatabase {
        if let database {
            return database
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try OxiDBDatabase.open(path: root.path)
        self.database = database
        return database
    }

    public func close() {
        database?.close()
        database = nil
    }

    @discardableResult
    public func execute(
        command: [String: Any],
        tolerateAlreadyExists: Bool = false
    ) throws -> [String: Any] {
        do {
            let database = try open()
            return try database.execute(command)
        } catch {
            let message = Self.errorMessage(from: error)
            if tolerateAlreadyExists, message.lowercased().contains("exist") {
                return ["ok": false, "error": message]
            }
            throw error
        }
    }

    static func parseCollectionNames(from response: [String: Any]) -> [String] {
        if let names = response["data"] as? [String] {
            return names
        }
        if let objects = response["data"] as? [[String: Any]] {
            return objects.compactMap { item in
                (item["name"] as? String) ?? (item["collection"] as? String)
            }
        }
        return []
    }

    static func errorMessage(from error: Error) -> String {
        if let error = error as? OxiDBError {
            switch error {
            case .connectionFailed:
                return "Failed to connect to OxiDB server."
            case .databaseOpenFailed:
                return "Failed to open OxiDB database."
            case .operationFailed(let message):
                return message
            case .transactionConflict(let message):
                return message
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }
        return String(describing: error)
    }
}
