import Crypto
import Foundation

public enum BotwireCanonicalSnapshotHash {
    public static func dataHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return dataHash(data)
    }
}

public enum BotwireCanonicalSnapshotDiff {
    public static func differenceLabels<Content: Encodable>(
        localContent: Content,
        remoteContent: Content,
        localPartHashes: [String: String],
        remotePartHashes: [String: String],
        fallbackLabel: String = "Project structure, algorithms, or settings"
    ) -> [String] {
        guard let localProjectHash = BotwireCanonicalSnapshotHash.hash(localContent),
              let remoteProjectHash = BotwireCanonicalSnapshotHash.hash(remoteContent),
              localProjectHash != remoteProjectHash else {
            return []
        }

        let allLabels = Set(localPartHashes.keys).union(remotePartHashes.keys)
        let changedLabels = allLabels
            .filter { localPartHashes[$0] != remotePartHashes[$0] }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return changedLabels.isEmpty ? [fallbackLabel] : changedLabels
    }
}
