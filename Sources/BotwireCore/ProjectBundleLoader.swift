import Foundation

public enum ProjectBundleLoaderError: LocalizedError {
    case fileNotFound(String)
    case unreadable(String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Project file does not exist: \(path)"
        case .unreadable(let path):
            return "Project file could not be read: \(path)"
        case .invalidJSON(let message):
            return "Project JSON is invalid: \(message)"
        }
    }
}

public enum ProjectBundleLoader {
    public static func load(path: String) throws -> BotwireProjectBundle {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectBundleLoaderError.fileNotFound(path)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw ProjectBundleLoaderError.unreadable(path)
        }
        do {
            return try JSONDecoder().decode(BotwireProjectBundle.self, from: data)
        } catch {
            throw ProjectBundleLoaderError.invalidJSON(error.localizedDescription)
        }
    }

    public static func writeSample(path: String) throws {
        let source = """
        function main() {
          Botwire.agent.updateStatus('running sample AgentBlock');
          Botwire.agent.complete({
            success: true,
            summary: 'Hello from Botwire AgentBlock',
            objective: Botwire.agent.objective
          });
        }
        """
        let bundle = BotwireProjectBundle(
            id: "sample",
            name: "Sample Botwire Project",
            description: "Minimal portable project bundle for botwire-runner.",
            agentBlock: BotwireAgentBlock(id: "sample-agentblock", name: "Sample AgentBlock", source: source)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
