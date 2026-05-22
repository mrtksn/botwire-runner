//
//  LinuxPerformanceTrace.swift
//  BotwireRuntime
//
//  Performance trace models and collector for the Linux runner.
//  Mirrors the iOS PerformanceTrace.swift data models so traces
//  from remote deployments can be deserialized by the iOS app.
//

import Foundation

// MARK: - Span Kind

public enum SpanKind: String, Codable, CaseIterable, Sendable {
    case algorithmRun
    case codeblockExecution
    case databaseRead
    case databaseWrite
    case networkFetch
    case networkStream
    case fileRead
    case fileWrite
    case fileList
    case llmConfigLoad
    case agentTurn
    case timerWait
    case busDispatch
    case custom
}

// MARK: - Performance Span

public struct PerformanceSpan: Codable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    public let kind: SpanKind
    public let label: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var durationMs: Int
    public var metadata: [String: String]
    public var success: Bool
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        kind: SpanKind,
        label: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        durationMs: Int = 0,
        metadata: [String: String] = [:],
        success: Bool = true,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.label = label
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.metadata = metadata
        self.success = success
        self.errorMessage = errorMessage
    }
}

// MARK: - Performance Trace

public struct PerformanceTrace: Codable, Sendable {
    public let id: UUID
    public let startupID: UUID
    public let startupName: String
    public let algorithmID: UUID
    public let algorithmName: String
    public let trigger: String
    public let sourcePeerID: String?
    public let sourcePeerName: String?
    public let startedAt: Date
    public var finishedAt: Date?
    public var success: Bool
    public var totalDurationMs: Int
    public var spans: [PerformanceSpan]

    public init(
        id: UUID = UUID(),
        startupID: UUID,
        startupName: String,
        algorithmID: UUID,
        algorithmName: String,
        trigger: String,
        sourcePeerID: String? = nil,
        sourcePeerName: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        success: Bool = true,
        totalDurationMs: Int = 0,
        spans: [PerformanceSpan] = []
    ) {
        self.id = id
        self.startupID = startupID
        self.startupName = startupName
        self.algorithmID = algorithmID
        self.algorithmName = algorithmName
        self.trigger = trigger
        self.sourcePeerID = sourcePeerID
        self.sourcePeerName = sourcePeerName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.success = success
        self.totalDurationMs = totalDurationMs
        self.spans = spans
    }
}

// MARK: - Performance Trace Collector

public final class PerformanceTraceCollector: @unchecked Sendable {

    public let traceID: UUID
    public let startupID: UUID
    public let startupName: String
    public let algorithmID: UUID
    public let algorithmName: String
    public let trigger: String
    public let traceStartedAt: Date

    private let lock = NSLock()
    private var spans: [PerformanceSpan] = []
    private var openSpans: [UUID: (span: PerformanceSpan, startTime: UInt64)] = [:]

    public init(
        startupID: UUID,
        startupName: String,
        algorithmID: UUID,
        algorithmName: String,
        trigger: String
    ) {
        self.traceID = UUID()
        self.startupID = startupID
        self.startupName = startupName
        self.algorithmID = algorithmID
        self.algorithmName = algorithmName
        self.trigger = trigger
        self.traceStartedAt = Date()
    }

    @discardableResult
    public func beginSpan(
        kind: SpanKind,
        label: String,
        parentID: UUID? = nil,
        metadata: [String: String] = [:]
    ) -> UUID {
        let spanID = UUID()
        let span = PerformanceSpan(
            id: spanID,
            parentID: parentID,
            kind: kind,
            label: label,
            startedAt: Date(),
            durationMs: 0,
            metadata: metadata,
            success: true
        )
        lock.lock()
        openSpans[spanID] = (span: span, startTime: DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
        return spanID
    }

    public func endSpan(
        id: UUID,
        success: Bool = true,
        error: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let endTime = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard var entry = openSpans.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let durationNs = endTime - entry.startTime
        entry.span.finishedAt = Date()
        entry.span.durationMs = Int(durationNs / 1_000_000)
        entry.span.success = success
        entry.span.errorMessage = error
        for (k, v) in metadata {
            entry.span.metadata[k] = v
        }
        spans.append(entry.span)
        lock.unlock()
    }

    public func finalize(success: Bool) -> PerformanceTrace {
        lock.lock()
        let endTime = DispatchTime.now().uptimeNanoseconds
        for (id, var entry) in openSpans {
            let durationNs = endTime - entry.startTime
            entry.span.finishedAt = Date()
            entry.span.durationMs = Int(durationNs / 1_000_000)
            entry.span.success = false
            entry.span.errorMessage = entry.span.errorMessage ?? "Span never closed (execution terminated)"
            spans.append(entry.span)
            openSpans.removeValue(forKey: id)
        }
        let finalSpans = spans
        lock.unlock()

        let finishedAt = Date()
        let totalMs = Int(finishedAt.timeIntervalSince(traceStartedAt) * 1000)

        return PerformanceTrace(
            id: traceID,
            startupID: startupID,
            startupName: startupName,
            algorithmID: algorithmID,
            algorithmName: algorithmName,
            trigger: trigger,
            startedAt: traceStartedAt,
            finishedAt: finishedAt,
            success: success,
            totalDurationMs: totalMs,
            spans: finalSpans
        )
    }
}
