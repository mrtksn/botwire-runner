import BotwireCore
import Foundation

public final class UnavailableJavaScriptCoreExecutor: BotwireJSExecutor {
    public init() {}

    public func cancel() {}

    public func execute(_ request: BotwireJSExecutionRequest, runID: String) async -> BotwireJSExecutionReport {
        BotwireJSExecutionReport(
            success: false,
            events: [
                BotwireRunEvent(runID: runID, kind: .started, message: "AgentBlock execution requested."),
                BotwireRunEvent(runID: runID, kind: .failed, message: "JavaScriptCore backend is not linked.")
            ],
            errorMessage: "JavaScriptCore is not available in this build. Add the Linux WebKitGTK/WPE JavaScriptCore C shim target for jsc/jsc.h.",
            durationMs: 0
        )
    }
}
