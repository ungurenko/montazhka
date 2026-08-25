import Foundation
import Testing

@testable import MontazhkaKit

/// In-memory адаптер для тестов: не трогает реальный UserDefaults.
/// Потокобезопасность — NSLock; конформер соответствия Sendable.
private final class InMemoryPreferenceStore: PreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { strings[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { strings[key] = value }
    }

    func bool(forKey key: String) -> Bool {
        lock.withLock { bools[key] ?? false }
    }

    func set(_ value: Bool, forKey key: String) {
        lock.withLock { bools[key] = value }
    }
}

@Suite
struct PreferenceStoreTests {
    @Test
    func testStringRoundTrip() {
        let store = InMemoryPreferenceStore()
        store.set("qwen/qwen3.7-flash", forKey: "smartEdit.openRouterModel")

        #expect(store.string(forKey: "smartEdit.openRouterModel") == "qwen/qwen3.7-flash")
        #expect(store.string(forKey: "missing") == nil)

        store.set(nil, forKey: "smartEdit.openRouterModel")
        #expect(store.string(forKey: "smartEdit.openRouterModel") == nil)
    }

    @Test
    func testBoolRoundTrip() {
        let store = InMemoryPreferenceStore()
        #expect(store.bool(forKey: "shorts.cropVertical") == false)

        store.set(true, forKey: "shorts.cropVertical")
        #expect(store.bool(forKey: "shorts.cropVertical") == true)

        store.set(false, forKey: "shorts.cropVertical")
        #expect(store.bool(forKey: "shorts.cropVertical") == false)
    }

    @Test
    func testSmartEditModelSaveAndLoadViaStore() {
        let store = InMemoryPreferenceStore()

        #expect(SmartEditModel.saved(in: store) == .qwen)

        SmartEditModel.deepSeek.save(in: store)
        #expect(SmartEditModel.saved(in: store) == .deepSeek)

        SmartEditModel.qwen.save(in: store)
        #expect(SmartEditModel.saved(in: store) == .qwen)
    }

    @Test
    func testShortsCountSaveAndLoadViaStore() {
        let store = InMemoryPreferenceStore()

        #expect(ShortsCount.saved(in: store) == .five)

        ShortsCount.eight.save(in: store)
        #expect(ShortsCount.saved(in: store) == .eight)
    }
}
