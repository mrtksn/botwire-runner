import BotwirePersistence
import XCTest

final class OxiModelStoreTests: XCTestCase {
    func testInMemoryStoreSavesAndFetchesTypedModels() async throws {
        let store = InMemoryOxiModelStore()
        let engine = StoredAgenticEngine(id: "engine-1", name: "Engine", source: "function main() {}")

        try await store.save(engine)
        let fetched = try await store.fetchOne(StoredAgenticEngine.self, id: "engine-1")

        XCTAssertEqual(fetched?.id, "engine-1")
        XCTAssertEqual(fetched?.name, "Engine")
    }

    func testSettingsSyncDecodesAppExportedShapesIntoPortableModels() throws {
        let json = """
        {
          "llmProfiles": [
            {
              "id": "openai",
              "name": "OpenAI",
              "baseURL": "https://api.openai.com/v1/chat/completions",
              "apiKey": "sk-test",
              "model": "gpt-4.1"
            }
          ],
          "agentProfiles": [
            {
              "id": "coder",
              "user": {
                "id": "coder-user",
                "name": "Coder",
                "description": "Writes code",
                "role": "assistant",
                "avatarURL": null,
                "isCurrentUser": false
              },
              "type": "openAICompatable",
              "systemPrompt": "Build carefully.",
              "tools": [{"name": "project_read"}],
              "contexts": [{"key": "runtime"}],
              "skillIDs": ["11111111-1111-1111-1111-111111111111"],
              "apiProfileID": "openai"
            }
          ],
          "skills": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "Review",
              "skillDescription": "Review work",
              "markdown": "Check behavior.",
              "createdAt": 0,
              "updatedAt": 0,
              "isGenerated": false
            }
          ],
          "contexts": [
            {
              "key": "runtime",
              "name": "Runtime",
              "contextDescription": "Runtime APIs",
              "content": "Use Botwire.",
              "scriptSource": "",
              "executionMode": "staticText",
              "isEnabled": true,
              "isDefault": true,
              "createdAt": 0,
              "updatedAt": 0
            }
          ]
        }
        """

        let payload = try JSONDecoder().decode(BotwireSettingsSyncPayload.self, from: Data(json.utf8))

        XCTAssertEqual(payload.llmProfiles?.first?.id, "openai")
        XCTAssertEqual(payload.llmProfiles?.first?.featureSupport.tags.count, 2)
        XCTAssertEqual(payload.agentProfiles?.first?.name, "Coder")
        XCTAssertEqual(payload.agentProfiles?.first?.toolsJSON.contains("project_read"), true)
        XCTAssertEqual(payload.agentProfiles?.first?.contextsJSON?.contains("runtime"), true)
        XCTAssertEqual(payload.skills?.first?.id, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(payload.contexts?.first?.id, "runtime")
    }
}
