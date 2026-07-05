import Foundation
import Testing
@testable import AgentInboxCore

@Test
func stateStorePersistsSettingsAndCompletedSessionsInSQLite() async throws {
    let root = try makeTemporaryStateRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appending(path: "state.sqlite")
    let store = StateStore(databaseURL: databaseURL)
    let state = PersistedState(
        pinMode: .todoOnly,
        completedSessionIDs: ["session-a", "session-b"],
        trackingStartedAt: Date(timeIntervalSince1970: 123_456)
    )

    await store.save(state)

    let loaded = await store.load()

    #expect(loaded.pinMode == .todoOnly)
    #expect(loaded.completedSessionIDs == ["session-a", "session-b"])
    #expect(abs(loaded.trackingStartedAt.timeIntervalSince1970 - 123_456) < 0.001)
    #expect(loaded.panelAnchor == nil) // 未保存过锚点 → nil
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))
}

@Test
func stateStoreInitializesTrackingBaselineOnFirstLoad() async throws {
    let root = try makeTemporaryStateRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appending(path: "state.sqlite")
    let store = StateStore(databaseURL: databaseURL)
    let before = Date()
    let first = await store.load()
    let after = Date()
    let second = await store.load()

    #expect(first.pinMode == .todoOnly)
    // 首次 load 就写入 tracking_started_at,后续启动复用同一基线,不把旧 rollout 变成待办
    #expect(first.trackingStartedAt >= before)
    #expect(first.trackingStartedAt <= after)
    #expect(abs(second.trackingStartedAt.timeIntervalSince1970 - first.trackingStartedAt.timeIntervalSince1970) < 0.001)
}

@Test
func stateStorePersistsPanelAnchorRoundtrip() async throws {
    let root = try makeTemporaryStateRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = StateStore(databaseURL: root.appending(path: "state.sqlite"))

    // 保存锚点 → 加载还原(Double 文本表示保证 round-trip 精度,含负坐标)
    let anchor = PanelAnchor(topRightX: 1234.5, topRightY: -87.25)
    await store.save(PersistedState(panelAnchor: anchor))
    let loaded = await store.load()
    #expect(loaded.panelAnchor == anchor)

    // 保存 nil → 删除已有锚点行,加载回 nil
    await store.save(PersistedState(panelAnchor: nil))
    let cleared = await store.load()
    #expect(cleared.panelAnchor == nil)
}

private func makeTemporaryStateRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "agent-inbox-state-tests")
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
