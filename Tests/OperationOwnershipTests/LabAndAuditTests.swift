import XCTest
@testable import OperationOwnership

/// The lab numbers are derived by hand in the README's tick tables; these
/// tests pin them. Any change to anchoring, coalescing, draining or waste
/// accounting moves at least one of them.
final class LabTests: XCTestCase {
    private func metrics(_ scenario: LabScenario) -> [LabStrategy: LabMetrics] {
        Dictionary(uniqueKeysWithValues: OwnershipLab.compare(scenario).map { ($0.strategy, $0.metrics) })
    }

    func testNavigateAwayAndBack() throws {
        let result = metrics(.navigateAway)
        let taskBound = try XCTUnwrap(result[.taskBound])
        XCTAssertEqual(taskBound.executionsStarted, 2)
        XCTAssertEqual(taskBound.costSpent, 640)      // 4 ticks sunk + a full 12-tick restart
        XCTAssertEqual(taskBound.costWasted, 160)
        XCTAssertEqual(taskBound.cancelled, 1)
        XCTAssertEqual(taskBound.orphanedCompletions, 0)
        XCTAssertEqual(taskBound.resultsDelivered, 1)
        XCTAssertEqual(taskBound.lastResultTick, 17)

        let fireAndForget = try XCTUnwrap(result[.fireAndForget])
        XCTAssertEqual(fireAndForget.executionsStarted, 2)
        XCTAssertEqual(fireAndForget.costSpent, 960)  // the first stream finishes for nobody
        XCTAssertEqual(fireAndForget.costWasted, 480)
        XCTAssertEqual(fireAndForget.orphanedCompletions, 1)
        XCTAssertEqual(fireAndForget.lastResultTick, 17)

        let owned = try XCTUnwrap(result[.owned])
        XCTAssertEqual(owned.executionsStarted, 1)
        XCTAssertEqual(owned.coalescedJoins, 1)
        XCTAssertEqual(owned.costSpent, 480)
        XCTAssertEqual(owned.costWasted, 0)
        XCTAssertEqual(owned.orphanedCompletions, 0)
        XCTAssertEqual(owned.resultsDelivered, 1)
        XCTAssertEqual(owned.lastResultTick, 11)      // the returning screen waits 6 ticks, not 12
    }

    func testSignOutEndsOwnedWorkButKeepsTheUpload() throws {
        let result = metrics(.signOut)
        let taskBound = try XCTUnwrap(result[.taskBound])
        XCTAssertEqual(taskBound.cancelled, 2, "the generation *and* the draft upload die with the screen")
        XCTAssertEqual(taskBound.costWasted, 200)
        XCTAssertEqual(taskBound.durableCompletions, 0)
        XCTAssertEqual(taskBound.orphanedCompletions, 0)

        let fireAndForget = try XCTUnwrap(result[.fireAndForget])
        XCTAssertEqual(fireAndForget.cancelled, 0)
        XCTAssertEqual(fireAndForget.orphanedCompletions, 2, "the stream keeps running after sign-out")
        XCTAssertEqual(fireAndForget.costWasted, 480)
        XCTAssertEqual(fireAndForget.durableCompletions, 0)

        let owned = try XCTUnwrap(result[.owned])
        XCTAssertEqual(owned.cancelled, 1, "sign-out ends the session's generation")
        XCTAssertEqual(owned.costWasted, 200)
        XCTAssertEqual(owned.durableCompletions, 1, "the must-finish upload lands")
        XCTAssertEqual(owned.orphanedCompletions, 0)
        XCTAssertEqual(owned.resultsDelivered, 0)
        XCTAssertNil(owned.lastResultTick)
    }

    func testBurstCoalescesOntoOneExecution() throws {
        let result = metrics(.burst)
        for strategy in [LabStrategy.taskBound, .fireAndForget] {
            let baseline = try XCTUnwrap(result[strategy])
            XCTAssertEqual(baseline.executionsStarted, 4, "\(strategy)")
            XCTAssertEqual(baseline.costSpent, 800, "\(strategy)")
            XCTAssertEqual(baseline.resultsDelivered, 4, "\(strategy)")
            XCTAssertEqual(baseline.lastResultTick, 31, "\(strategy)")
        }
        let owned = try XCTUnwrap(result[.owned])
        XCTAssertEqual(owned.executionsStarted, 2)
        XCTAssertEqual(owned.coalescedJoins, 2)
        XCTAssertEqual(owned.costSpent, 400)
        XCTAssertEqual(owned.resultsDelivered, 4)
        XCTAssertEqual(owned.lastResultTick, 15)
    }

    /// Mirrors the demo app's app-owned scenario so its README numbers are pinned here too.
    func testSearchAsYouTypeWithReplace() throws {
        let network = Lane("network")
        let scenario = LabScenario(
            id: "search", title: "search", summary: "", endTick: 10,
            lanes: [network: LaneLimits(maxConcurrent: 4, maxQueued: 8)],
            steps: [
                .init(0, .open("session", .session, parent: nil)),
                .init(0, .open("browse", .flow, parent: "session")),
                .init(0, .open("search-field", .view, parent: "browse")),
            ] + ["s", "sw", "swi", "swif"].enumerated().map { index, query in
                LabScenario.TimedStep(index, .request(LabRequest(
                    owner: "search-field", intent: "Query \(query)", resource: "search-results", lane: network,
                    ownedLifetime: .owner, ownedSharing: .replace, durationTicks: 3, costPerTick: 10)))
            })
        let result = metrics(scenario)
        for strategy in [LabStrategy.taskBound, .fireAndForget] {
            let baseline = try XCTUnwrap(result[strategy])
            XCTAssertEqual(baseline.costSpent, 120, "\(strategy)")
            XCTAssertEqual(baseline.costWasted, 0, "\(strategy)")
            XCTAssertEqual(baseline.resultsDelivered, 4, "\(strategy)")
            XCTAssertEqual(baseline.lastResultTick, 5, "\(strategy)")
        }
        let owned = try XCTUnwrap(result[.owned])
        XCTAssertEqual(owned.costSpent, 40)
        XCTAssertEqual(owned.costWasted, 10)
        XCTAssertEqual(owned.cancelled, 3)
        XCTAssertEqual(owned.resultsDelivered, 1)
        XCTAssertEqual(owned.lastResultTick, 6)
    }

    func testEveryLabFramePassesTheAudit() {
        for scenario in LabScenario.presets {
            for run in OwnershipLab.compare(scenario) {
                XCTAssertEqual(run.frames.count, scenario.endTick + 1)
                for frame in run.frames {
                    let violations = LedgerAudit.snapshot(frame.snapshot, lanes: scenario.lanes)
                    XCTAssertEqual(violations, [], "\(scenario.id)/\(run.strategy) tick \(frame.tick)")
                }
            }
        }
    }

    func testOwnedFrameShowsTheSessionKeepingTheStreamAlive() throws {
        let run = OwnershipLab.run(.navigateAway, strategy: .owned)
        // Tick 5: the first screen is gone and the second has not opened yet.
        let frame = try XCTUnwrap(run.frames.first { $0.tick == 5 })
        let op = try XCTUnwrap(frame.snapshot.operations.first)
        XCTAssertEqual(op.state, .running)
        XCTAssertEqual(op.claims.map(\.anchor), ["session"])
        XCTAssertEqual(op.claims.map(\.awaiting), [false])
        XCTAssertFalse(frame.snapshot.owners.contains { $0.label == "reply-screen#1" })
    }

    func testScenarioEdgeCasesAreClamped() {
        let empty = LabScenario(id: "e", title: "e", summary: "", endTick: -3, lanes: [:], steps: [])
        let run = OwnershipLab.run(empty, strategy: .owned)
        XCTAssertEqual(run.frames.count, 1)
        XCTAssertEqual(run.metrics, LabMetrics())

        let huge = LabScenario(id: "h", title: "h", summary: "", endTick: Int.max, lanes: [:], steps: [])
        XCTAssertEqual(huge.endTick, LabScenario.maxTicks)

        let request = LabRequest(owner: "nobody", intent: "x", resource: "x", lane: Lane("llm"),
                                 ownedLifetime: .owner, durationTicks: 0, costPerTick: -9)
        XCTAssertEqual(request.durationTicks, 1)
        XCTAssertEqual(request.costPerTick, 0)
        let orphanStep = LabScenario(id: "o", title: "o", summary: "", endTick: 2, lanes: [Lane("llm"): .init(maxConcurrent: 1, maxQueued: 1)],
                                     steps: [.init(0, .request(request))])
        XCTAssertEqual(OwnershipLab.run(orphanStep, strategy: .owned).metrics.rejectedRequests, 1)
    }
}

/// Proves each checker can fail, then runs a long seeded random walk through
/// the real ledger under all of them.
final class AuditTests: XCTestCase {
    func testEffectAuditCatchesABrokenStream() {
        let op = OperationID(raw: 1)
        let claim = ClaimID(raw: 1)
        XCTAssertEqual(LedgerAudit.effects([.start(op), .resolve(claim, .completed(op))]), [])
        XCTAssertEqual(LedgerAudit.effects([.resolve(claim, .superseded), .resolve(claim, .completed(op))]).count, 1)
        XCTAssertEqual(LedgerAudit.effects([.start(op), .cancel(op), .start(op)]).count, 2) // after cancel + twice
        XCTAssertEqual(LedgerAudit.effects([.cancel(op)]).count, 1)
    }

    func testSnapshotAuditCatchesBrokenStates() {
        let claim = OwnershipSnapshot.ClaimRow(id: ClaimID(raw: 1), requester: "v", anchor: "v", lifetime: .owner, awaiting: true)
        func row(_ id: UInt64, _ state: OwnershipLedger.OperationState, claims: [OwnershipSnapshot.ClaimRow]) -> OwnershipSnapshot.OperationRow {
            .init(id: OperationID(raw: id), intent: "x", resource: nil, lane: llm, state: state, priority: .normal,
                  consumed: 0, reservedRemaining: 0, claims: claims)
        }
        let lanes = [llm: LaneLimits(maxConcurrent: 1, maxQueued: 0)]
        let broken = OwnershipSnapshot(
            owners: [], operations: [row(1, .running, claims: [claim]),
                                     row(2, .draining, claims: [claim]),  // over capacity and still claimed
                                     row(3, .queued, claims: [])],         // over queue and ownerless
            budget: TokenBudget(capacity: 10), totals: LedgerTotals())
        XCTAssertEqual(LedgerAudit.snapshot(broken, lanes: lanes).map(\.message), [
            "llm: 2 active > maxConcurrent 1",
            "llm: 1 waiting > maxQueued 0",
            "op2 is draining but still has 1 claim(s)",
            "op3 is queued with no owner",
        ])
        XCTAssertEqual(LedgerAudit.snapshot(broken, lanes: [:]).map(\.message), [
            "operations on unconfigured lane llm",
            "op2 is draining but still has 1 claim(s)",
            "op3 is queued with no owner",
        ])
        XCTAssertEqual(LedgerAudit.batch([.start(OperationID(raw: 1)), .cancel(OperationID(raw: 1))]).map(\.message),
                       ["op1 started and cancelled in one batch"])
        XCTAssertEqual(LedgerAudit.budget(capacity: 10, reserved: 6, spent: 5).count, 1)
        XCTAssertEqual(LedgerAudit.budget(capacity: 10, reserved: -1, spent: 0).count, 1)
        XCTAssertEqual(LedgerAudit.budget(capacity: Int.max, reserved: Int.max, spent: 1).count, 1)
        XCTAssertEqual(LedgerAudit.budget(capacity: 10, reserved: 4, spent: 6), [])
    }

    /// A deliberately broken ownership model — "cancel as soon as *any*
    /// requester leaves", which is what binding shared work to one view's
    /// `.task` does — must fail the survival property the README claims.
    func testSurvivalPropertyFailsForTheTaskBoundModel() throws {
        func survivesFirstRequesterLeaving(_ strategy: LabStrategy) -> Bool {
            let run = OwnershipLab.run(.navigateAway, strategy: strategy)
            return run.frames.first { $0.tick == 5 }?.snapshot.operations.contains { $0.state == .running } ?? false
        }
        XCTAssertTrue(survivesFirstRequesterLeaving(.owned))
        XCTAssertFalse(survivesFirstRequesterLeaving(.taskBound))
    }

    func testSeededRandomWalkHoldsEveryInvariant() throws {
        // Deliberately unequal lanes sharing the same few resources: the
        // cross-lane promotion paths only show up when one lane is full and
        // the other has room.
        let lanes = [llm: LaneLimits(maxConcurrent: 1, maxQueued: 3), io: LaneLimits(maxConcurrent: 3, maxQueued: 2)]
        for seed in UInt64(1)...UInt64(200) {
            var rng = SplitMix(seed: seed)
            var ledger = OwnershipLedger(configuration: .init(lanes: lanes, budgetCapacity: 2_000, maxOwners: 24,
                                                              historyCapacity: 16, eventCapacity: 16))
            var stream: [LedgerEffect] = []
            var accepted: Set<ClaimID> = []
            let lifetimes: [Lifetime] = [.owner, .scope(.flow), .scope(.session), .scope(.app), .mustFinish]
            let sharings: [Sharing] = [.coalesce, .replace, .serialize, .rejectIfBusy, .independent]

            func record(_ effects: [LedgerEffect]) {
                stream.append(contentsOf: effects)
                XCTAssertEqual(LedgerAudit.batch(effects), [], "seed \(seed)")
                XCTAssertEqual(ledger.auditResourceQueues(), [], "seed \(seed)")
                let violations = LedgerAudit.snapshot(ledger.snapshot(), lanes: lanes)
                XCTAssertEqual(violations, [], "seed \(seed)")
            }

            for _ in 0..<400 {
                let owners = ledger.snapshot().owners
                switch rng.next(9) {
                case 0, 1:
                    guard let parent = rng.pick(owners), parent.kind > .view,
                          let kind = rng.pick(ScopeKind.allCases.filter { $0 < parent.kind }) else { continue }
                    _ = try? ledger.openOwner(kind, label: "o", parent: parent.id)
                case 2:
                    guard let victim = rng.pick(owners.filter { $0.id != ledger.root }) else { continue }
                    record((try? ledger.closeOwner(victim.id)) ?? [])
                case 3, 4:
                    guard let owner = rng.pick(owners), let lifetime = rng.pick(lifetimes),
                          let sharing = rng.pick(sharings) else { continue }
                    let req = OperationRequest(intent: "w", owner: owner.id, resource: ResourceKey("r\(rng.next(2))"),
                                               lane: rng.next(2) == 0 ? llm : io, lifetime: lifetime, sharing: sharing,
                                               priority: rng.pick(Priority.allCases) ?? .normal,
                                               costEstimate: rng.next(120))
                    if case .accepted(let claim, _, _, let effects) = ledger.submit(req) {
                        accepted.insert(claim)
                        record(effects)
                    }
                case 5:
                    guard let claim = rng.pick(accepted.sorted()) else { continue }
                    record(ledger.detach(claim))
                case 6:
                    guard let op = rng.pick(ledger.runningOperations) else { continue }
                    record(ledger.consume(op, amount: rng.next(80)).effects)
                default:
                    guard let op = rng.pick(ledger.runningOperations + ledger.drainingOperations) else { continue }
                    record(ledger.finish(op, rng.next(5) == 0 ? .failure("boom") : .success))
                }
            }

            // Teardown: close everything, then let all work finish or drain.
            for owner in ledger.snapshot().owners where owner.depth == 1 {
                record((try? ledger.closeOwner(owner.id)) ?? [])
            }
            var guardrail = 0
            while ledger.operationCount > 0, guardrail < 1_000 {
                guardrail += 1
                for op in ledger.runningOperations + ledger.drainingOperations {
                    record(ledger.finish(op, .success))
                }
            }

            XCTAssertEqual(ledger.operationCount, 0, "seed \(seed): work left behind")
            XCTAssertEqual(ledger.claimCount, 0, "seed \(seed): claims leaked")
            XCTAssertEqual(ledger.budget.reserved, 0, "seed \(seed): reservation leaked")
            XCTAssertEqual(LedgerAudit.effects(stream), [], "seed \(seed)")
            let resolved = Set(stream.compactMap { effect -> ClaimID? in
                if case .resolve(let claim, _) = effect { return claim }
                return nil
            })
            XCTAssertEqual(resolved, accepted, "seed \(seed): every accepted claim is resolved exactly once")
        }
    }
}

/// Deterministic PRNG so the random walk is reproducible from its seed.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform-enough value in `0..<bound`; returns 0 for a non-positive bound.
    mutating func next(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(nextRaw() % UInt64(bound))
    }

    mutating func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        let index = next(items.count)
        return items.indices.contains(index) ? items[index] : nil
    }
}
