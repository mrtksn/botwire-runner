import BotwireCore
import Foundation
#if canImport(OxiDB)
import OxiDB
#endif

public actor NativeOxiModelStore: OxiModelStore {
    private let store: OxiDBEmbeddedStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var initializedCollections = Set<String>()
    
    private var observers: [String: [UUID: @Sendable () async -> Void]] = [:]

    public init(root: URL) {
        self.store = OxiDBEmbeddedStore(root: root)
    }

    public func fetch<T: OxiModel>(_ type: T.Type, query: OxiQuery = .all) async throws -> [T] {
        
        var command: [String: Any] = [
            "collection": T.collectionName,
            "cmd": "find"
        ]
        
        if !query.fields.isEmpty {
            var filter: [String: Any] = [:]
            for (k, v) in query.fields {
                filter[k] = v.jsonObject
            }
            command["query"] = filter
        }
        
        if let limit = query.limit {
            command["limit"] = limit
        }
        
        let response = try store.execute(command: command)
        
        let dataArray: [[String: Any]]
        if let docs = response["docs"] as? [[String: Any]] {
            dataArray = docs
        } else if let res = response["result"] as? [[String: Any]] {
            dataArray = res
        } else if let data = response["data"] as? [[String: Any]] {
            dataArray = data
        } else {
            // Default to empty array if no familiar array key is found
            dataArray = []
        }
        
        var models: [T] = []
        for dict in dataArray {
            let data = try JSONSerialization.data(withJSONObject: dict)
            if let model = try? decoder.decode(T.self, from: data) {
                models.append(model)
            }
        }
        
        models.sort { $0.updatedAt > $1.updatedAt }
        return models
    }

    public func save<T: OxiModel>(_ model: T) async throws {
        let data = try encoder.encode(model)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NativeOxiModelStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize model"])
        }
        
        _ = try? store.execute(command: [
            "collection": T.collectionName,
            "cmd": "delete",
            "query": ["id": model.id]
        ], tolerateAlreadyExists: true)
        
        _ = try store.execute(command: [
            "collection": T.collectionName,
            "cmd": "insert",
            "doc": dict
        ])
        
        await notify(collection: T.collectionName)
    }

    public func delete<T: OxiModel>(_ type: T.Type, id: String) async throws {
        _ = try store.execute(command: [
            "collection": T.collectionName,
            "cmd": "delete",
            "query": ["id": id]
        ])
        await notify(collection: T.collectionName)
    }

    public func transaction<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await body()
    }

    public nonisolated func observe<T: OxiModel>(_ type: T.Type, query: OxiQuery = .all) -> AsyncStream<[T]> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await addObserver(id: id, collection: T.collectionName) {
                    let values = (try? await self.fetch(T.self, query: query)) ?? []
                    continuation.yield(values)
                }
                let values = (try? await self.fetch(T.self, query: query)) ?? []
                continuation.yield(values)
            }
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id: id, collection: T.collectionName) }
            }
        }
    }

    private func addObserver(id: UUID, collection: String, callback: @escaping @Sendable () async -> Void) {
        var collectionObservers = observers[collection] ?? [:]
        collectionObservers[id] = callback
        observers[collection] = collectionObservers
    }

    private func removeObserver(id: UUID, collection: String) {
        observers[collection]?[id] = nil
    }

    private func notify(collection: String) async {
        let callbacks = observers[collection].map { Array($0.values) } ?? []
        for callback in callbacks {
            await callback()
        }
    }
}

fileprivate extension JSONValue {
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
