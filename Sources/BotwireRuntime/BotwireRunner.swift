import BotwireCore
import Foundation

public struct BotwireRunner: Sendable {
    public var executor: BotwireJSExecutor

    public init(executor: BotwireJSExecutor = BotwireJSExecutorFactory.makeDefault()) {
        self.executor = executor
    }

    public func run(_ request: BotwireRunRequest) async -> BotwireJSExecutionReport {
        guard let agentBlock = request.project.agentBlock else {
            return BotwireJSExecutionReport(
                success: false,
                events: [
                    BotwireRunEvent(runID: request.runID, kind: .failed, message: "Project has no AgentBlock.")
                ],
                errorMessage: "Project has no agentBlock source to run."
            )
        }

        return await executor.execute(
            BotwireJSExecutionRequest(
                source: agentBlock.source,
                objective: request.objective,
                inputJSON: request.inputJSON,
                projectId: request.project.id,
                workspacePath: request.workspacePath
            ),
            runID: request.runID
        )
    }
}
