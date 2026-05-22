import BotwireCore
import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore

public final class AppleJavaScriptCoreExecutor: @unchecked Sendable, BotwireJSExecutor {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func execute(_ request: BotwireJSExecutionRequest, runID: String) async -> BotwireJSExecutionReport {
        let started = Date()
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "botwire.runner.jsc").async {
                var logs: [String] = []
                var events: [BotwireRunEvent] = [
                    BotwireRunEvent(runID: runID, kind: .started, message: "AgentBlock execution started.")
                ]
                var completedPayload: JSONValue?
                var didComplete = false

                let context = JSContext()!
                context.exceptionHandler = { _, exception in
                    if let exception {
                        logs.append("JavaScript exception: \(exception.toString() ?? "unknown")")
                    }
                }

                let consoleLog: @convention(block) (JSValue) -> Void = { value in
                    logs.append(value.toString() ?? String(describing: value))
                }

                let updateStatus: @convention(block) (String) -> Void = { message in
                    events.append(BotwireRunEvent(runID: runID, kind: .status, message: message))
                }

                let complete: @convention(block) (JSValue) -> Void = { value in
                    completedPayload = Self.jsonValue(from: value)
                    didComplete = true
                    events.append(BotwireRunEvent(runID: runID, kind: .completed, message: "AgentBlock completed."))
                }

                context.setObject(consoleLog, forKeyedSubscript: "__botwireConsoleLog" as NSString)
                context.setObject(updateStatus, forKeyedSubscript: "__botwireUpdateStatus" as NSString)
                context.setObject(complete, forKeyedSubscript: "__botwireComplete" as NSString)

                let objective = Self.escapeForSingleQuotedJavaScript(request.objective)
                let input = Self.escapeForSingleQuotedJavaScript(request.inputJSON ?? "null")
                let bootstrap = """
                var console = {
                  log: function(value) { __botwireConsoleLog(String(value)); }
                };
                var Botwire = {
                  input: JSON.parse('\(input)'),
                  agent: {
                    objective: '\(objective)',
                    updateStatus: function(message) { __botwireUpdateStatus(String(message)); },
                    complete: function(payload) { __botwireComplete(payload); }
                  }
                };
                """

                _ = context.evaluateScript(bootstrap)
                _ = context.evaluateScript(request.source)

                if self.isCancelled {
                    continuation.resume(returning: BotwireJSExecutionReport(
                        success: false,
                        logs: logs,
                        events: events + [BotwireRunEvent(runID: runID, kind: .failed, message: "Execution cancelled.")],
                        errorMessage: "Execution cancelled.",
                        durationMs: Self.durationMs(since: started)
                    ))
                    return
                }

                if context.objectForKeyedSubscript("main")?.isUndefined == false {
                    _ = context.evaluateScript("""
                    try {
                      var __botwireMainResult = main();
                      if (__botwireMainResult && typeof __botwireMainResult.then === 'function') {
                        __botwireMainResult
                          .then(function(value) {
                            if (value !== undefined && !\(didComplete ? "true" : "false")) Botwire.agent.complete(value);
                          })
                          .catch(function(error) {
                            __botwireComplete({ success: false, error: String(error && error.stack ? error.stack : error) });
                          });
                      } else if (__botwireMainResult !== undefined) {
                        Botwire.agent.complete(__botwireMainResult);
                      }
                    } catch (error) {
                      __botwireComplete({ success: false, error: String(error && error.stack ? error.stack : error) });
                    }
                    """)
                }

                let deadline = Date().addingTimeInterval(request.timeout)
                while !didComplete && Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                if let exception = context.exception {
                    events.append(BotwireRunEvent(runID: runID, kind: .failed, message: "JavaScript exception."))
                    continuation.resume(returning: BotwireJSExecutionReport(
                        success: false,
                        logs: logs,
                        events: events,
                        errorMessage: exception.toString(),
                        durationMs: Self.durationMs(since: started)
                    ))
                    return
                }

                guard didComplete else {
                    events.append(BotwireRunEvent(runID: runID, kind: .failed, message: "AgentBlock timed out."))
                    continuation.resume(returning: BotwireJSExecutionReport(
                        success: false,
                        logs: logs,
                        events: events,
                        errorMessage: "AgentBlock did not complete within \(Int(request.timeout))s.",
                        durationMs: Self.durationMs(since: started)
                    ))
                    return
                }

                continuation.resume(returning: BotwireJSExecutionReport(
                    success: true,
                    result: completedPayload,
                    logs: logs,
                    events: events,
                    durationMs: Self.durationMs(since: started)
                ))
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func durationMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private static func jsonValue(from value: JSValue) -> JSONValue {
        if value.isNull || value.isUndefined {
            return .null
        }
        if value.isBoolean {
            return .bool(value.toBool())
        }
        if value.isNumber {
            return .number(value.toDouble())
        }
        if value.isString {
            return .string(value.toString() ?? "")
        }
        if let object = value.toObject() {
            return jsonValue(fromFoundation: object)
        }
        return .string(value.toString() ?? "")
    }

    private static func jsonValue(fromFoundation object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case let value as String:
            return .string(value)
        case let values as [Any]:
            return .array(values.map(jsonValue(fromFoundation:)))
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(jsonValue(fromFoundation:)))
        default:
            return .string(String(describing: object))
        }
    }

    private static func escapeForSingleQuotedJavaScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
#endif
