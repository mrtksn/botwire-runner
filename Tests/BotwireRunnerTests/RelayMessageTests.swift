import BotwireRelay
import XCTest

final class RelayMessageTests: XCTestCase {
    func testHeartbeatEnvelopeEncoding() throws {
        let payload = RunnerHeartbeatPayload(runnerID: "runner-1", runnerName: "Linux Runner")
        let envelope = BotwireRelayEnvelope(type: .runnerHeartbeat, payload: payload)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(BotwireRelayEnvelope<RunnerHeartbeatPayload>.self, from: data)

        XCTAssertEqual(decoded.type, .runnerHeartbeat)
        XCTAssertEqual(decoded.payload.runnerID, "runner-1")
    }
}
