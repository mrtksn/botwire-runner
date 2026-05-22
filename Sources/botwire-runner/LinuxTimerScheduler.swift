import BotwireCore
import Foundation

extension BotwireRunnerCLI {
    static func runTimerScheduler(config: BotwireRunnerConfig, store: CloudResourceStore) async {
        var lastFired: [String: Date] = [:]
        var tickCounts: [String: Int] = [:]
        let formatter = ISO8601DateFormatter()

        while !Task.isCancelled {
            do {
                let now = Date()
                let bundles = try await store.projects()
                var desired = Set<String>()

                for bundle in bundles {
                    guard await store.isStartupActive(startupID: bundle.id) else { continue }

                    for algorithm in bundle.algorithms where timerEntryPoint(for: algorithm.id, in: bundle) {
                        let key = "\(bundle.id):\(algorithm.id)"
                        desired.insert(key)
                        let interval = timerIntervalSeconds(for: algorithm.id, in: bundle)

                        guard let last = lastFired[key] else {
                            lastFired[key] = now
                            tickCounts[key] = 0
                            continue
                        }
                        guard now.timeIntervalSince(last) >= TimeInterval(interval) else { continue }
                        lastFired[key] = now
                        tickCounts[key, default: 0] += 1

                        guard let codeBlock = algorithm.codeBlocks.first(where: { $0.role == .logic }) else {
                            emitCloudEvent("timer.skipped", [
                                "startupID": bundle.id,
                                "algorithmID": algorithm.id,
                                "reason": "no logic code block"
                            ])
                            continue
                        }

                        let inputJSON = botwireJSONString([
                            "tick": tickCounts[key, default: 1],
                            "scheduledAt": formatter.string(from: now),
                            "algorithmID": algorithm.id,
                            "timerName": algorithm.name,
                            "intervalSeconds": interval
                        ])
                        let result = await CloudExecutionResultFactory.executeCodeBlock(
                            startupID: bundle.id,
                            algorithmID: algorithm.id,
                            codeBlock: codeBlock,
                            inputJSON: inputJSON,
                            workspacePath: config.workspacePath,
                            runID: UUID().uuidString,
                            trigger: "timer",
                            traceStore: store
                        )
                        emitCloudEvent(result.success ? "timer.finished" : "timer.failed", [
                            "startupID": bundle.id,
                            "algorithmID": algorithm.id,
                            "algorithmName": algorithm.name,
                            "tick": tickCounts[key, default: 1],
                            "durationMs": Int(result.finishedAt.timeIntervalSince(result.startedAt) * 1000)
                        ])
                    }
                }

                for key in lastFired.keys where !desired.contains(key) {
                    lastFired.removeValue(forKey: key)
                    tickCounts.removeValue(forKey: key)
                }
            } catch {
                print("timer: scheduler scan failed: \(error.localizedDescription)")
            }

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    static func timerEntryPoint(for algorithmID: String, in bundle: BotwireProjectBundle) -> Bool {
        bundle.metadata["algorithm.\(algorithmID).entryPoint"] == "timer"
    }

    static func timerIntervalSeconds(for algorithmID: String, in bundle: BotwireProjectBundle) -> Int {
        if let raw = bundle.metadata["algorithm.\(algorithmID).timerIntervalSeconds"],
           let interval = Int(raw) {
            return max(10, interval)
        }
        if let json = bundle.metadata["algorithm.\(algorithmID).timerProperty"],
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let interval = botwireTimerIntervalSeconds(from: object) {
            return max(10, interval)
        }
        return 60
    }

    static func storeTimerMetadata(from algoSnap: [String: Any], algorithmID: String, into metadata: inout [String: String]) {
        if let timerProperty = algoSnap["timerProperty"] as? [String: Any],
           let interval = botwireTimerIntervalSeconds(from: timerProperty) {
            metadata["algorithm.\(algorithmID).timerIntervalSeconds"] = String(max(10, interval))
            metadata["algorithm.\(algorithmID).timerProperty"] = botwireJSONString(timerProperty)
        } else if let interval = botwireTimerIntervalSeconds(from: algoSnap) {
            metadata["algorithm.\(algorithmID).timerIntervalSeconds"] = String(max(10, interval))
            metadata["algorithm.\(algorithmID).timerProperty"] = botwireJSONString([
                "label": "Timer",
                "intervalSeconds": max(10, interval)
            ])
        }
    }

    static func timerSnapshotPayload(for algorithmID: String, in bundle: BotwireProjectBundle) -> [String: Any]? {
        if let json = bundle.metadata["algorithm.\(algorithmID).timerProperty"],
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard timerEntryPoint(for: algorithmID, in: bundle) else { return nil }
        return [
            "label": "Timer",
            "intervalSeconds": timerIntervalSeconds(for: algorithmID, in: bundle)
        ]
    }
}

func botwireTimerIntervalSeconds(from object: [String: Any]) -> Int? {
    if let value = object["intervalSeconds"] as? Int { return value }
    if let value = object["intervalSeconds"] as? Double { return Int(value) }
    if let value = object["intervalSeconds"] as? String, let intValue = Int(value) { return intValue }
    if let value = object["timerIntervalSeconds"] as? Int { return value }
    if let value = object["timerIntervalSeconds"] as? Double { return Int(value) }
    if let value = object["timerIntervalSeconds"] as? String, let intValue = Int(value) { return intValue }
    return nil
}

func botwireJSONString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}
