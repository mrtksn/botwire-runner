import BotwireCore
import XCTest

final class ProjectBundleLoaderTests: XCTestCase {
    func testSampleProjectRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sample-\(UUID().uuidString).botwire.json")
        try ProjectBundleLoader.writeSample(path: url.path)

        let project = try ProjectBundleLoader.load(path: url.path)

        XCTAssertEqual(project.schemaVersion, 1)
        XCTAssertEqual(project.id, "sample")
        XCTAssertNotNil(project.agentBlock)
        XCTAssertTrue(project.agentBlock?.source.contains("Botwire.agent.complete") == true)
    }
}
