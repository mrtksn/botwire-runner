import BotwireCore
import Foundation

public protocol OxiModel: Codable, Identifiable, Sendable where ID == String {
    static var collectionName: String { get }
    var id: String { get }
    var updatedAt: Date { get set }
}

public struct OxiQuery: Codable, Sendable, Equatable {
    public var fields: [String: JSONValue]
    public var limit: Int?

    public static let all = OxiQuery()

    public init(fields: [String: JSONValue] = [:], limit: Int? = nil) {
        self.fields = fields
        self.limit = limit
    }

    public static func id(_ id: String) -> OxiQuery {
        OxiQuery(fields: ["id": .string(id)], limit: 1)
    }
}

public protocol OxiModelStore: Sendable {
    func fetch<T: OxiModel>(_ type: T.Type, query: OxiQuery) async throws -> [T]
    func save<T: OxiModel>(_ model: T) async throws
    func delete<T: OxiModel>(_ type: T.Type, id: String) async throws
    func transaction<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
    func observe<T: OxiModel>(_ type: T.Type, query: OxiQuery) -> AsyncStream<[T]>
}

public extension OxiModelStore {
    func fetch<T: OxiModel>(_ type: T.Type, query: OxiQuery = .all) async throws -> [T] {
        try await fetch(type, query: query)
    }

    func fetchOne<T: OxiModel>(_ type: T.Type, id: String) async throws -> T? {
        try await fetch(type, query: .id(id)).first
    }
}
