import XCTest
@testable import OperationOwnership

/// A one-shot latch for steering real tasks without sleeping.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Waits (by yielding, never sleeping) until `condition` holds; bounded.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<20_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

final class OperationCenterTests: XCTestCase {
    private func makeCenter(budget: Int = 10_000) -> OperationCenter {
        OperationCenter(configuration: .init(lanes: [llm: .init(maxConcurrent: 2, maxQueued: 4)], budgetCapacity: budget))
    }

    func testPerformReturnsTheValue() async throws {
        let center = makeCenter()
        let root = await center.root
        let view = try await center.openOwner(.view, label: "v", parent: root)
        let value = try await center.perform(request(view, cost: 5)) { context in
            try await context.consume(3)
            return "hello"
        }
        XCTAssertEqual(value, "hello")
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.budget.spent, 3)
        XCTAssertEqual(snapshot.budget.reserved, 0)
        XCTAssertEqual(snapshot.totals.delivered, 1)
        let leftovers = await (center.pendingWorkCount, center.waiterCount, center.earlyCount)
        XCTAssertEqual(leftovers.0, 0)
        XCTAssertEqual(leftovers.1, 0)
        XCTAssertEqual(leftovers.2, 0)
    }

    func testConcurrentCallersShareOneExecution() async throws {
        let center = makeCenter()
        let root = await center.root
        let a = try await center.openOwner(.view, label: "a", parent: root)
        let b = try await center.openOwner(.view, label: "b", parent: root)
        let gate = Gate()
        let executions = Counter()
        let work: @Sendable (OperationContext) async throws -> Int = { _ in
            await executions.increment()
            await gate.wait()
            return 42
        }
        async let first = center.perform(request(a), work)
        async let second = center.perform(request(b), work)
        let joined = await eventually { await center.snapshot().operations.first?.claims.count == 2 }
        XCTAssertTrue(joined, "both callers should hold claims on one operation")
        await gate.open()
        let values = try await [first, second]
        XCTAssertEqual(values, [42, 42])
        let count = await executions.value
        XCTAssertEqual(count, 1)
        let totals = await center.snapshot().totals
        XCTAssertEqual(totals.coalescedJoins, 1)
        XCTAssertEqual(totals.started, 1)
    }

    func testCancellingTheCallerOfSessionScopedWorkLeavesItRunning() async throws {
        let center = makeCenter()
        let root = await center.root
        let session = try await center.openOwner(.session, label: "s", parent: root)
        let view = try await center.openOwner(.view, label: "v", parent: session)
        let gate = Gate()
        let finished = Counter()
        let caller = Task {
            try await center.perform(request(view, lifetime: .scope(.session))) { _ in
                await gate.wait()
                await finished.increment()
                return 1
            }
        }
        let running = await eventually { await center.snapshot().operations.first?.state == .running }
        XCTAssertTrue(running)
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("the caller was cancelled and should not receive the value")
        } catch {
            XCTAssertEqual(error as? OperationError, .callerCancelled)
        }
        let stillRunning = await center.snapshot().operations.first?.state
        XCTAssertEqual(stillRunning, .running, "the session, not the caller, owns this work")
        await gate.open()
        let done = await eventually { await center.snapshot().operations.isEmpty }
        XCTAssertTrue(done)
        let count = await finished.value
        XCTAssertEqual(count, 1)
        let totals = await center.snapshot().totals
        XCTAssertEqual(totals.retained, 1, "nobody awaited it, but the session still owned it")
        XCTAssertEqual(totals.delivered, 0)
        XCTAssertEqual(totals.cancelled, 0)
    }

    func testCancellingTheCallerOfStructuredWorkCancelsTheTask() async throws {
        let center = makeCenter()
        let root = await center.root
        let view = try await center.openOwner(.view, label: "v", parent: root)
        let gate = Gate()
        let observedCancel = Counter()
        let caller = Task {
            try await center.perform(request(view)) { _ in
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    Task { await gate.open() }
                }
                if Task.isCancelled { await observedCancel.increment() }
                return 0
            }
        }
        let running = await eventually { await center.snapshot().operations.first?.state == .running }
        XCTAssertTrue(running)
        caller.cancel()
        await XCTAssertThrowsAsync(try await caller.value, .callerCancelled)
        let drained = await eventually { await center.snapshot().operations.isEmpty }
        XCTAssertTrue(drained)
        let cancels = await observedCancel.value
        XCTAssertEqual(cancels, 1, "the work itself saw cancellation")
        let workLeft = await center.pendingWorkCount
        XCTAssertEqual(workLeft, 0)
    }

    func testClosingTheOwnerResolvesTheCallerAndCancelsTheWork() async throws {
        let center = makeCenter()
        let root = await center.root
        let view = try await center.openOwner(.view, label: "v", parent: root)
        let caller = Task {
            try await center.perform(request(view)) { (context: OperationContext) -> Int in
                while true { // A stream: one token per chunk until told to stop.
                    try await context.consume(1)
                    await Task.yield()
                }
            }
        }
        let spending = await eventually { await center.snapshot().budget.spent > 3 }
        XCTAssertTrue(spending)
        try await center.closeOwner(view)
        await XCTAssertThrowsAsync(try await caller.value, .requesterClosed)
        let drained = await eventually { await center.snapshot().operations.isEmpty }
        XCTAssertTrue(drained)
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.totals.cancelled, 1)
        XCTAssertEqual(snapshot.budget.reserved, 0)
        XCTAssertEqual(snapshot.totals.wastedCost, snapshot.budget.spent, "every token of a cancelled stream is waste")
    }

    func testOutrunningTheBudgetStopsTheStream() async throws {
        let center = makeCenter(budget: 20)
        let root = await center.root
        let view = try await center.openOwner(.view, label: "v", parent: root)
        await XCTAssertThrowsAsync(try await center.perform(request(view, cost: 10)) { context in
            for _ in 0..<100 { try await context.consume(5) }
            return 0
        }, .budgetExceeded)
        let drained = await eventually { await center.snapshot().operations.isEmpty }
        XCTAssertTrue(drained)
        let budget = await center.snapshot().budget
        XCTAssertEqual(budget.spent, 20)
        XCTAssertEqual(budget.reserved, 0)
    }

    func testRejectionsAndFailuresSurfaceAsTypedErrors() async throws {
        let center = makeCenter(budget: 5)
        let root = await center.root
        let view = try await center.openOwner(.view, label: "v", parent: root)
        await XCTAssertThrowsAsync(try await center.perform(request(view, cost: 6)) { _ in 0 }, .rejected(.budgetExhausted))
        await XCTAssertThrowsAsync(try await center.perform(request(view, resource: "f", cost: 0)) { _ -> Int in
            throw TestFailure()
        }, .failed(String(describing: TestFailure())))
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await center.perform(request(view, cost: 0)) { _ in 0 }
        }
        await XCTAssertThrowsAsync(try await alreadyCancelled.value, .rejected(.callerCancelled))
    }

    func testCoalescingDifferentResultTypesIsATypeMismatch() async throws {
        let center = makeCenter()
        let root = await center.root
        let view = try await center.openOwner(.view, label: "v", parent: root)
        let gate = Gate()
        async let number = center.perform(request(view)) { _ -> Int in
            await gate.wait()
            return 1
        }
        let started = await eventually { await center.snapshot().operations.count == 1 }
        XCTAssertTrue(started)
        async let text = center.perform(request(view)) { _ -> String in "never runs" }
        let joined = await eventually { await center.snapshot().operations.first?.claims.count == 2 }
        XCTAssertTrue(joined)
        await gate.open()
        let numberValue = try await number
        XCTAssertEqual(numberValue, 1)
        do {
            _ = try await text
            XCTFail("expected a type mismatch")
        } catch {
            XCTAssertEqual(error as? OperationError, .typeMismatch)
        }
    }
}

actor ContextBox {
    var context: OperationContext?
    func store(_ context: OperationContext) { self.context = context }
}

final class WeakCenterBox: @unchecked Sendable {
    // Written once on the test's task before any concurrent read.
    weak var center: OperationCenter?
}

final class OperationContextLifetimeTests: XCTestCase {
    func testAContextThatOutlivesItsCenterReportsStop() async throws {
        let box = ContextBox()
        let weakBox = WeakCenterBox()
        do {
            let center = OperationCenter(configuration: .init(lanes: [llm: .init(maxConcurrent: 1, maxQueued: 0)],
                                                              budgetCapacity: 10))
            weakBox.center = center
            let root = await center.root
            let view = try await center.openOwner(.view, label: "v", parent: root)
            _ = try await center.perform(request(view, cost: 0)) { context in
                await box.store(context)
                return 0
            }
        }
        let released = await eventually { weakBox.center == nil }
        XCTAssertTrue(released, "the center must not be kept alive by its finished task or by the context")
        let stored = await box.context
        let context = try XCTUnwrap(stored)
        do {
            try await context.consume(1)
            XCTFail("a context whose center is gone must tell the work to stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String { "TestFailure" }
}

func XCTAssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: OperationError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? OperationError, expected, file: file, line: line)
    }
}
