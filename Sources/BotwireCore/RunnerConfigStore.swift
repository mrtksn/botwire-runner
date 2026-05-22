import Foundation

public enum RunnerConfigStoreError: LocalizedError {
    case missingConfig(String)
    case unreadable(String)
    case invalidConfig(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let path):
            return "Runner config does not exist: \(path)"
        case .unreadable(let path):
            return "Runner config could not be read: \(path)"
        case .invalidConfig(let message):
            return "Runner config is invalid: \(message)"
        }
    }
}

public enum RunnerConfigStore {
    public static let defaultPath = "/etc/botwire-runner/config.json"

    public static func load(path: String = defaultPath) throws -> BotwireRunnerConfig {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RunnerConfigStoreError.missingConfig(path)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw RunnerConfigStoreError.unreadable(path)
        }
        do {
            return try JSONDecoder().decode(BotwireRunnerConfig.self, from: data)
        } catch {
            throw RunnerConfigStoreError.invalidConfig(error.localizedDescription)
        }
    }

    public static func save(_ config: BotwireRunnerConfig, path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
