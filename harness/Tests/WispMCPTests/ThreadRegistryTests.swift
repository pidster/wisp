import Testing

@testable import WispMCP

@Suite struct ThreadRegistryTests {
    @Test func createsFindsAndCloses() async throws {
        let store = ThreadRegistry<String>(capacity: 4)
        _ = try await store.create(id: "a") { "A" }
        #expect(await store.find("a") == "A")
        #expect(await store.find("b") == nil)
        try await store.close("a")
        #expect(await store.find("a") == nil)
    }

    @Test func rejectsDuplicateAndUnknownIds() async throws {
        let store = ThreadRegistry<String>(capacity: 4)
        _ = try await store.create(id: "a") { "A" }
        await #expect(throws: ThreadRegistry<String>.Failure.alreadyExists("a")) {
            try await store.create(id: "a") { "A2" }
        }
        await #expect(throws: ThreadRegistry<String>.Failure.notFound("zz")) { try await store.close("zz") }
    }

    @Test func evictsLeastRecentlyUsedAtCapacityAndReportsIt() async throws {
        let store = ThreadRegistry<String>(capacity: 2)
        #expect(try await store.create(id: "a") { "A" }.evicted == nil)
        _ = try await store.create(id: "b") { "B" }
        _ = await store.find("a")  // b is now least recently used
        #expect(try await store.create(id: "c") { "C" }.evicted?.id == "b")
        #expect(await store.ids == ["c", "a"])
        #expect(await store.find("b") == nil)
    }

    @Test func findOrCreateIsIdempotentForOneId() async throws {
        let store = ThreadRegistry<String>(capacity: 4)
        let first = try await store.findOrCreate(id: "x") { "X1" }
        let second = try await store.findOrCreate(id: "x") { "X2" }
        #expect(first.created && first.thread == "X1")
        #expect(!second.created && second.thread == "X1")
        #expect(second.evicted == nil)
    }

    @Test func factoryErrorsDoNotStoreAThread() async {
        struct Boom: Error {}
        let store = ThreadRegistry<String>(capacity: 2)
        await #expect(throws: Boom.self) { try await store.create(id: "a") { throw Boom() } }
        #expect(await store.ids.isEmpty)
    }
}
