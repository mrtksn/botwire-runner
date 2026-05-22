import BotwireCore
import Foundation

public actor InMemoryOxiModelStore: OxiModelStore {
    private var collections: [String: [String: Data]] = [:]
    private var observers: [String: [UUID: @Sendable () async -> Void]] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func fetch<T: OxiModel>(_ type: T.Type, query: OxiQuery = .all) async throws -> [T] {
        let documents = collections[T.collectionName] ?? [:]
        var models = try documents.values.map { try decoder.decode(T.self, from: $0) }
        models = models.filter { model in
            query.fields.allSatisfy { key, value in
                matches(model: model, key: key, value: value)
            }
        }
        models.sort { $0.updatedAt > $1.updatedAt }
        if let limit = query.limit {
            return Array(models.prefix(limit))
        }
        return models
    }

    public func save<T: OxiModel>(_ model: T) async throws {
        var collection = collections[T.collectionName] ?? [:]
        collection[model.id] = try encoder.encode(model)
        collections[T.collectionName] = collection
        await notify(collection: T.collectionName)
    }

    public func delete<T: OxiModel>(_ type: T.Type, id: String) async throws {
        collections[T.collectionName]?[id] = nil
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

    private func matches<T: OxiModel>(model: T, key: String, value: JSONValue) -> Bool {
        guard let data = try? encoder.encode(model),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let actual = object[key] else {
            return false
        }
        return actual == value
    }
}
