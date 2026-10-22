import XCTest
@testable import OperationOwnership

let llm = Lane("llm")
let io = Lane("io")

func makeLedger(llm llmLimits: LaneLimits = .init(maxConcurrent: 2, maxQueued: 4),
                budget: Int = 100_000, maxOwners: Int = 64) -> OwnershipLedger {
    OwnershipLedger(configuration: .init(
        lanes: [llm: llmLimits, io: .init(maxConcurrent: 2, maxQueued: 4)],
        budgetCapacity: budget, maxOwners: maxOwners, historyCapacity: 8, eventCapacity: 16))
}

/// A session → flow → two views tree, the shape most tests need.
struct Tree {
    var ledger: OwnershipLedger
    let session: OwnerID
    let flow: OwnerID
    let viewA: OwnerID
    let viewB: OwnerID
}

func makeTree(_ ledger: OwnershipLedger = makeLedger()) throws -> Tree {
    var ledger = ledger
    let session = try ledger.openOwner(.session, label: "session", parent: ledger.root)
    let flow = try ledger.openOwner(.flow, label: "flow", parent: session)
    let viewA = try ledger.openOwner(.view, label: "A", parent: flow)
    let viewB = try ledger.openOwner(.view, label: "B", parent: flow)
    return Tree(ledger: ledger, session: session, flow: flow, viewA: viewA, viewB: viewB)
}

func request(_ owner: OwnerID, resource: String? = "r", lane: Lane = llm, lifetime: Lifetime = .owner,
             sharing: Sharing = .coalesce, priority: Priority = .normal, cost: Int = 10) -> OperationRequest {
    OperationRequest(intent: "work", owner: owner, resource: resource.map(ResourceKey.init), lane: lane,
                     lifetime: lifetime, sharing: sharing, priority: priority, costEstimate: cost)
}

/// Unwraps an accepted submission or fails the test.
func accept(_ outcome: OwnershipLedger.SubmitOutcome, file: StaticString = #filePath, line: UInt = #line)
    -> (claim: ClaimID, op: OperationID, joined: Bool, effects: [LedgerEffect])? {
    guard case .accepted(let claim, let op, let joined, let effects) = outcome else {
        XCTFail("expected acceptance, got \(outcome)", file: file, line: line)
        return nil
    }
    return (claim, op, joined, effects)
}

final class OwnerTreeTests: XCTestCase {
    func testNestingMustStrictlyWiden() throws {
        var ledger = makeLedger()
        let session = try ledger.openOwner(.session, label: "s", parent: ledger.root)
        XCTAssertThrowsError(try ledger.openOwner(.session, label: "dup", parent: session)) { error in
            XCTAssertEqual(error as? OwnerError, .invalidNesting(child: .session, parent: .session))
        }
        XCTAssertThrowsError(try ledger.openOwner(.account, label: "up", parent: session))
        XCTAssertThrowsError(try ledger.openOwner(.app, label: "second root", parent: ledger.root))
        // Skipping levels is allowed: a view directly under the session.
        XCTAssertNoThrow(try ledger.openOwner(.view, label: "v", parent: session))
    }

    func testUnknownParentRootAndCapacity() throws {
        var ledger = makeLedger(maxOwners: 2) // root + one
        XCTAssertThrowsError(try ledger.openOwner(.view, label: "x", parent: OwnerID(raw: 999))) {
            XCTAssertEqual($0 as? OwnerError, .unknownParent)
        }
        XCTAssertThrowsError(try ledger.closeOwner(ledger.root)) { XCTAssertEqual($0 as? OwnerError, .cannotCloseRoot) }
        XCTAssertThrowsError(try ledger.closeOwner(OwnerID(raw: 42))) { XCTAssertEqual($0 as? OwnerError, .unknownOwner) }
        _ = try ledger.openOwner(.session, label: "s", parent: ledger.root)
        XCTAssertThrowsError(try ledger.openOwner(.view, label: "over", parent: ledger.root)) {
            XCTAssertEqual($0 as? OwnerError, .capacityReached)
        }
    }

    func testClosingRemovesWholeSubtreeAndFreesCapacity() throws {
        var tree = try makeTree()
        XCTAssertEqual(tree.ledger.ownerCount, 5)
        _ = try tree.ledger.closeOwner(tree.session)
        XCTAssertEqual(tree.ledger.ownerCount, 1)
        XCTAssertFalse(tree.ledger.isOpen(tree.viewA))
        XCTAssertEqual(tree.ledger.snapshot().owners.map(\.label), ["app"])
    }

    func testScopeAnchorResolvesToNearestEnclosingKind() throws {
        let tree = try makeTree()
        XCTAssertEqual(tree.ledger.anchor(for: .owner, requester: tree.viewA), tree.viewA)
        XCTAssertEqual(tree.ledger.anchor(for: .scope(.flow), requester: tree.viewA), tree.flow)
        XCTAssertEqual(tree.ledger.anchor(for: .scope(.session), requester: tree.viewA), tree.session)
        // No account in the chain: the root is the only owner wide enough.
        XCTAssertEqual(tree.ledger.anchor(for: .scope(.account), requester: tree.viewA), tree.ledger.root)
        XCTAssertNil(tree.ledger.anchor(for: .mustFinish, requester: tree.viewA))
    }
}

final class OwnershipSemanticsTests: XCTestCase {
    /// Guarantee 1: one of several requesters leaving must not cancel shared work.
    func testCoalescedWorkSurvivesOneRequesterLeaving() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA))),
              let b = accept(tree.ledger.submit(request(tree.viewB))) else { return }
        XCTAssertEqual(a.effects, [.start(a.op)])
        XCTAssertTrue(b.joined)
        XCTAssertEqual(b.op, a.op)
        XCTAssertEqual(tree.ledger.budget.reserved, 10, "a joiner must not reserve a second estimate")

        let closeA = try tree.ledger.closeOwner(tree.viewA)
        XCTAssertEqual(closeA, [.resolve(a.claim, .requesterClosed)])
        XCTAssertEqual(tree.ledger.state(of: a.op), .running)
        XCTAssertEqual(tree.ledger.liveClaimCount(of: a.op), 1)

        let closeB = try tree.ledger.closeOwner(tree.viewB)
        XCTAssertEqual(closeB, [.resolve(b.claim, .requesterClosed), .cancel(a.op)])
        XCTAssertEqual(tree.ledger.state(of: a.op), .draining)
    }

    func testSessionScopedWorkOutlivesTheScreenButNotTheSession() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA, lifetime: .scope(.session)))) else { return }
        XCTAssertEqual(try tree.ledger.closeOwner(tree.viewA), [.resolve(a.claim, .requesterClosed)])
        XCTAssertEqual(tree.ledger.state(of: a.op), .running, "the session still owns the generation")

        // A new screen asking for the same resource joins the surviving work.
        let viewC = try tree.ledger.openOwner(.view, label: "C", parent: tree.flow)
        guard let c = accept(tree.ledger.submit(request(viewC, lifetime: .scope(.session)))) else { return }
        XCTAssertTrue(c.joined)
        XCTAssertEqual(c.op, a.op)

        XCTAssertEqual(try tree.ledger.closeOwner(tree.session), [.resolve(c.claim, .requesterClosed), .cancel(a.op)])
    }

    func testStructuredWorkDiesWithItsView() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA))) else { return }
        XCTAssertEqual(try tree.ledger.closeOwner(tree.viewA), [.resolve(a.claim, .requesterClosed), .cancel(a.op)])
    }

    func testDetachReleasesStructuredClaimsAndKeepsWiderOnes() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA, resource: "x"))),
              let b = accept(tree.ledger.submit(request(tree.viewB, resource: "y", lifetime: .scope(.flow)))) else { return }
        XCTAssertEqual(tree.ledger.detach(a.claim), [.resolve(a.claim, .callerCancelled), .cancel(a.op)])
        XCTAssertEqual(tree.ledger.detach(b.claim), [.resolve(b.claim, .callerCancelled)])
        XCTAssertEqual(tree.ledger.state(of: b.op), .running)
        XCTAssertEqual(tree.ledger.detach(b.claim), [], "a second detach is a no-op, never a second resolution")
        XCTAssertEqual(tree.ledger.detach(ClaimID(raw: 9_999)), [])
    }

    func testMustFinishSurvivesSignOutAndCountsAsDurable() throws {
        var ledger = makeLedger()
        let account = try ledger.openOwner(.account, label: "acct", parent: ledger.root)
        let view = try ledger.openOwner(.view, label: "v", parent: account)
        guard let upload = accept(ledger.submit(request(view, resource: "draft", lane: io, lifetime: .mustFinish))) else { return }
        XCTAssertEqual(try ledger.closeOwner(account), [.resolve(upload.claim, .requesterClosed)])
        XCTAssertEqual(ledger.state(of: upload.op), .running)
        XCTAssertEqual(ledger.finish(upload.op, .success), [], "nobody is awaiting, so nothing is resolved")
        XCTAssertEqual(ledger.totals.durable, 1)
        XCTAssertEqual(ledger.totals.orphaned, 0)
        XCTAssertEqual(ledger.history.elements.last?.outcome, .completed(.durable))
    }

    func testAppScopedWorkWithNobodyWaitingIsOrphanedAndWasted() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA, lifetime: .scope(.app)))) else { return }
        _ = try tree.ledger.closeOwner(tree.viewA)
        XCTAssertTrue(tree.ledger.consume(a.op, amount: 7).proceed)
        _ = tree.ledger.finish(a.op, .success)
        XCTAssertEqual(tree.ledger.totals.orphaned, 1)
        XCTAssertEqual(tree.ledger.totals.wastedCost, 7)
    }

    func testCompletionResolvesEveryAwaitingClaimOnce() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA))),
              let b = accept(tree.ledger.submit(request(tree.viewB))) else { return }
        let effects = tree.ledger.finish(a.op, .success)
        XCTAssertEqual(effects, [.resolve(a.claim, .completed(a.op)), .resolve(b.claim, .completed(a.op))])
        XCTAssertEqual(tree.ledger.finish(a.op, .success), [], "a stale second finish is ignored")
        XCTAssertEqual(tree.ledger.claimCount, 0)
        XCTAssertEqual(tree.ledger.budget.reserved, 0)
        XCTAssertEqual(tree.ledger.totals.delivered, 1)
    }

    func testFailureResolvesClaimsAsFailedAndIsNotWaste() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA))) else { return }
        XCTAssertTrue(tree.ledger.consume(a.op, amount: 4).proceed)
        XCTAssertEqual(tree.ledger.finish(a.op, .failure("HTTP 529")), [.resolve(a.claim, .failed(a.op, "HTTP 529"))])
        XCTAssertEqual(tree.ledger.totals.failed, 1)
        XCTAssertEqual(tree.ledger.totals.wastedCost, 0)
        XCTAssertEqual(tree.ledger.budget.spent, 4)
    }
}

final class SharingTests: XCTestCase {
    func testReplaceSupersedesExistingClaims() throws {
        var tree = try makeTree()
        guard let first = accept(tree.ledger.submit(request(tree.viewA, sharing: .replace))),
              let second = accept(tree.ledger.submit(request(tree.viewB, sharing: .replace))) else { return }
        XCTAssertFalse(second.joined)
        XCTAssertNotEqual(first.op, second.op)
        XCTAssertEqual(second.effects, [.resolve(first.claim, .superseded), .cancel(first.op)])
        XCTAssertEqual(tree.ledger.state(of: first.op), .draining)
        // The victim still holds the resource until its task actually stops.
        XCTAssertEqual(tree.ledger.state(of: second.op), .waitingOnResource)
        XCTAssertEqual(tree.ledger.finish(first.op, .success), [.start(second.op)])
        XCTAssertEqual(tree.ledger.auditResourceQueues(), [])
    }

    func testSerializedResourceStaysExclusiveWhileTheHeadDrains() throws {
        var tree = try makeTree()
        guard let head = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))),
              let next = accept(tree.ledger.submit(request(tree.viewB, sharing: .serialize))) else { return }
        let close = try tree.ledger.closeOwner(tree.viewA)
        XCTAssertEqual(close, [.resolve(head.claim, .requesterClosed), .cancel(head.op)],
                       "the waiter must not start while the cancelled writer is still running")
        XCTAssertEqual(tree.ledger.state(of: next.op), .waitingOnResource)
        XCTAssertEqual(tree.ledger.finish(head.op, .success), [.start(next.op)])
    }

    func testClosingHeadAndWaiterTogetherStartsNothing() throws {
        var tree = try makeTree()
        guard let head = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))),
              let waiter = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))) else { return }
        let effects = try tree.ledger.closeOwner(tree.viewA)
        XCTAssertEqual(effects, [.resolve(head.claim, .requesterClosed), .cancel(head.op),
                                 .resolve(waiter.claim, .requesterClosed)])
        XCTAssertEqual(LedgerAudit.batch(effects), [])
        XCTAssertNil(tree.ledger.state(of: waiter.op))
    }

    func testReplaceOverASerializeQueueStartsNothingItCancels() throws {
        var tree = try makeTree()
        guard let head = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))),
              let waiter = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))),
              let latest = accept(tree.ledger.submit(request(tree.viewB, sharing: .replace))) else { return }
        XCTAssertEqual(latest.effects, [.resolve(head.claim, .superseded), .cancel(head.op),
                                        .resolve(waiter.claim, .superseded)])
        XCTAssertEqual(LedgerAudit.batch(latest.effects), [])
        XCTAssertEqual(tree.ledger.auditResourceQueues(), [])
        XCTAssertEqual(tree.ledger.finish(head.op, .success), [.start(latest.op)])
    }

    /// One resource used from two lanes: the head is queued on a full narrow
    /// lane, the waiter would fit on a wide lane. Releasing both in one call
    /// must not start (and then cancel) the waiter.
    private func crossLaneSetup() throws -> (Tree, head: (ClaimID, OperationID), waiter: (ClaimID, OperationID)) {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 4)))
        _ = accept(tree.ledger.submit(request(tree.viewB, resource: "blocker"))) // fills llm
        guard let head = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))),
              let waiter = accept(tree.ledger.submit(request(tree.viewA, lane: io, sharing: .serialize))) else {
            throw XCTSkip("setup failed")
        }
        XCTAssertEqual(tree.ledger.state(of: head.op), .queued)
        XCTAssertEqual(tree.ledger.state(of: waiter.op), .waitingOnResource)
        return (tree, (head.claim, head.op), (waiter.claim, waiter.op))
    }

    func testCrossLaneCloseStartsNothingItCancels() throws {
        var (tree, head, waiter) = try crossLaneSetup()
        let effects = try tree.ledger.closeOwner(tree.viewA)
        XCTAssertEqual(effects, [.resolve(head.0, .requesterClosed), .resolve(waiter.0, .requesterClosed)])
        XCTAssertEqual(LedgerAudit.batch(effects), [])
        XCTAssertEqual(tree.ledger.auditResourceQueues(), [])
    }

    func testCrossLaneReplaceKeepsTheResourceExclusive() throws {
        var (tree, head, waiter) = try crossLaneSetup()
        guard let latest = accept(tree.ledger.submit(request(tree.viewB, lane: io, sharing: .replace))) else { return }
        XCTAssertEqual(latest.effects, [.resolve(head.0, .superseded), .resolve(waiter.0, .superseded), .start(latest.op)])
        XCTAssertEqual(LedgerAudit.batch(latest.effects), [])
        XCTAssertEqual(tree.ledger.auditResourceQueues(), [])
    }

    func testCoalesceNeverJoinsDrainingWork() throws {
        var tree = try makeTree()
        guard let first = accept(tree.ledger.submit(request(tree.viewA))) else { return }
        _ = try tree.ledger.closeOwner(tree.viewA)
        guard let fresh = accept(tree.ledger.submit(request(tree.viewB))) else { return }
        XCTAssertFalse(fresh.joined)
        XCTAssertEqual(tree.ledger.state(of: fresh.op), .waitingOnResource)
        XCTAssertEqual(tree.ledger.finish(first.op, .success), [.start(fresh.op)])
    }

    func testJoinersAreCappedPerOperation() throws {
        var tree = try makeTree(OwnershipLedger(configuration: .init(
            lanes: [llm: .init(maxConcurrent: 1, maxQueued: 1)], budgetCapacity: 100, maxClaimsPerOperation: 2)))
        _ = accept(tree.ledger.submit(request(tree.viewA)))
        _ = accept(tree.ledger.submit(request(tree.viewB)))
        XCTAssertEqual(tree.ledger.submit(request(tree.viewB)), .rejected(.overloaded))
    }

    func testClosedRequestersKeepTheirNamesInSnapshots() throws {
        var tree = try makeTree()
        _ = accept(tree.ledger.submit(request(tree.viewA, lifetime: .scope(.session))))
        _ = try tree.ledger.closeOwner(tree.viewA)
        let claim = try XCTUnwrap(tree.ledger.snapshot().operations.first?.claims.first)
        XCTAssertEqual(claim.requester, "A (closed)")
        XCTAssertEqual(claim.anchor, "session")
        XCTAssertFalse(claim.awaiting)
    }

    func testReplaceNeverCancelsMustFinishWork() throws {
        var tree = try makeTree()
        guard let pinned = accept(tree.ledger.submit(request(tree.viewA, lifetime: .mustFinish))) else { return }
        XCTAssertEqual(tree.ledger.submit(request(tree.viewB, sharing: .replace)), .rejected(.resourcePinned))
        XCTAssertEqual(tree.ledger.state(of: pinned.op), .running)
    }

    func testReplaceIsRefusedWholeWhenTheNewWorkCannotBeAdmitted() throws {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 0)))
        guard let first = accept(tree.ledger.submit(request(tree.viewA, sharing: .replace))) else { return }
        // The only slot is busy and there is no queue: the replacement cannot run,
        // so the existing work must not be cancelled on its behalf.
        XCTAssertEqual(tree.ledger.submit(request(tree.viewB, sharing: .replace)), .rejected(.overloaded))
        XCTAssertEqual(tree.ledger.state(of: first.op), .running)
        XCTAssertEqual(tree.ledger.liveClaimCount(of: first.op), 1)
    }

    func testRejectIfBusy() throws {
        var tree = try makeTree()
        _ = accept(tree.ledger.submit(request(tree.viewA, sharing: .rejectIfBusy)))
        XCTAssertEqual(tree.ledger.submit(request(tree.viewB, sharing: .rejectIfBusy)), .rejected(.resourceBusy))
        XCTAssertEqual(tree.ledger.budget.reserved, 10, "a refusal holds no budget")
    }

    func testSerializeRunsPerResourceFIFO() throws {
        var tree = try makeTree()
        guard let first = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))),
              let second = accept(tree.ledger.submit(request(tree.viewB, sharing: .serialize))) else { return }
        XCTAssertEqual(second.effects, [], "the lane has room, but the resource does not")
        XCTAssertEqual(tree.ledger.state(of: second.op), .waitingOnResource)
        XCTAssertEqual(tree.ledger.finish(first.op, .success),
                       [.resolve(first.claim, .completed(first.op)), .start(second.op)])
    }

    func testCancellingAQueuedWaiterDoesNotDisturbTheHead() throws {
        var tree = try makeTree()
        guard let first = accept(tree.ledger.submit(request(tree.viewA, sharing: .serialize))),
              let second = accept(tree.ledger.submit(request(tree.viewB, sharing: .serialize))) else { return }
        XCTAssertEqual(try tree.ledger.closeOwner(tree.viewB), [.resolve(second.claim, .requesterClosed)])
        XCTAssertNil(tree.ledger.state(of: second.op))
        XCTAssertEqual(tree.ledger.state(of: first.op), .running)
        XCTAssertEqual(tree.ledger.budget.reserved, 10, "the cancelled waiter's reservation was released")
    }

    func testIndependentIgnoresTheResource() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA, sharing: .independent))),
              let b = accept(tree.ledger.submit(request(tree.viewB, sharing: .independent))) else { return }
        XCTAssertNotEqual(a.op, b.op)
        XCTAssertEqual(tree.ledger.runningOperations, [a.op, b.op])
    }
}

final class AdmissionTests: XCTestCase {
    /// Guarantee 3: a cancelled operation keeps its slot until it drains.
    func testLaneSlotIsHeldWhileDraining() throws {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 2)))
        guard let a = accept(tree.ledger.submit(request(tree.viewA, resource: "a"))) else { return }
        _ = try tree.ledger.closeOwner(tree.viewA)
        XCTAssertEqual(tree.ledger.state(of: a.op), .draining)
        guard let b = accept(tree.ledger.submit(request(tree.viewB, resource: "b"))) else { return }
        XCTAssertEqual(b.effects, [], "the draining task still occupies the only slot")
        XCTAssertEqual(tree.ledger.state(of: b.op), .queued)
        XCTAssertFalse(tree.ledger.consume(a.op, amount: 5).proceed, "draining work may not spend")
        XCTAssertEqual(tree.ledger.finish(a.op, .success), [.start(b.op)])
        XCTAssertEqual(tree.ledger.budget.spent, 0)
    }

    func testFullQueueRejectsWithoutHoldingBudget() throws {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 1)))
        _ = accept(tree.ledger.submit(request(tree.viewA, resource: "1")))
        _ = accept(tree.ledger.submit(request(tree.viewA, resource: "2")))
        XCTAssertEqual(tree.ledger.submit(request(tree.viewB, resource: "3")), .rejected(.overloaded))
        XCTAssertEqual(tree.ledger.budget.reserved, 20)
        XCTAssertEqual(tree.ledger.totals.rejected, 1)
    }

    func testHigherPriorityStartsFirstEvenWhenItArrivedLater() throws {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 4)))
        guard let blocker = accept(tree.ledger.submit(request(tree.viewA, resource: "blocker"))),
              accept(tree.ledger.submit(request(tree.viewA, resource: "bg", priority: .background))) != nil,
              let urgent = accept(tree.ledger.submit(request(tree.viewA, resource: "urgent", priority: .userInitiated))) else { return }
        XCTAssertEqual(tree.ledger.finish(blocker.op, .success).last, .start(urgent.op))
    }

    func testJoinerLiftsAQueuedOperationsPriority() throws {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 4)))
        guard let blocker = accept(tree.ledger.submit(request(tree.viewA, resource: "blocker"))),
              let normal = accept(tree.ledger.submit(request(tree.viewA, resource: "normal"))),
              let low = accept(tree.ledger.submit(request(tree.viewA, resource: "low", priority: .background))) else { return }
        // A user-initiated joiner lifts the later, background operation above `normal`.
        guard let lift = accept(tree.ledger.submit(request(tree.viewB, resource: "low", priority: .userInitiated))) else { return }
        XCTAssertEqual(lift.op, low.op)
        XCTAssertEqual(tree.ledger.finish(blocker.op, .success),
                       [.resolve(blocker.claim, .completed(blocker.op)), .start(low.op)])
        XCTAssertEqual(tree.ledger.finish(low.op, .success).last, .start(normal.op))
    }

    func testEqualPriorityIsFIFO() throws {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 4)))
        guard let blocker = accept(tree.ledger.submit(request(tree.viewA, resource: "0"))),
              let first = accept(tree.ledger.submit(request(tree.viewA, resource: "1"))),
              accept(tree.ledger.submit(request(tree.viewA, resource: "2"))) != nil else { return }
        XCTAssertEqual(tree.ledger.finish(blocker.op, .success).last, .start(first.op))
    }

    func testDoorChecks() throws {
        var tree = try makeTree()
        XCTAssertEqual(tree.ledger.submit(request(OwnerID(raw: 777))), .rejected(.unknownOwner))
        XCTAssertEqual(tree.ledger.submit(request(tree.viewA, lane: Lane("gpu"))), .rejected(.unknownLane))
        XCTAssertEqual(tree.ledger.submit(request(tree.viewA, cost: -1)), .rejected(.invalidEstimate))
        _ = try tree.ledger.closeOwner(tree.viewA)
        XCTAssertEqual(tree.ledger.submit(request(tree.viewA)), .rejected(.unknownOwner))
        XCTAssertEqual(tree.ledger.totals.rejected, 4)
        XCTAssertEqual(tree.ledger.operationCount, 0)
    }

    func testStaleFeedbackForUnstartedWorkIsIgnored() throws {
        var tree = try makeTree(makeLedger(llm: .init(maxConcurrent: 1, maxQueued: 2)))
        _ = accept(tree.ledger.submit(request(tree.viewA, resource: "a")))
        guard let queued = accept(tree.ledger.submit(request(tree.viewA, resource: "b"))) else { return }
        XCTAssertEqual(tree.ledger.finish(queued.op, .success), [])
        XCTAssertFalse(tree.ledger.consume(queued.op, amount: 1).proceed)
        XCTAssertEqual(tree.ledger.finish(OperationID(raw: 12_345), .success), [])
        XCTAssertEqual(tree.ledger.state(of: queued.op), .queued)
    }
}

final class BudgetTests: XCTestCase {
    func testReservationRefusedWhenBudgetIsShort() throws {
        var tree = try makeTree(makeLedger(budget: 25))
        _ = accept(tree.ledger.submit(request(tree.viewA, resource: "a", cost: 20)))
        XCTAssertEqual(tree.ledger.submit(request(tree.viewA, resource: "b", cost: 6)), .rejected(.budgetExhausted))
        XCTAssertNotNil(accept(tree.ledger.submit(request(tree.viewA, resource: "c", cost: 5))))
    }

    func testOverageDrawsFromFreeCapacityThenCancels() throws {
        var tree = try makeTree(makeLedger(budget: 30))
        guard let a = accept(tree.ledger.submit(request(tree.viewA, cost: 10))) else { return }
        XCTAssertTrue(tree.ledger.consume(a.op, amount: 25).proceed, "15 of overage fits in the free 20")
        XCTAssertEqual(tree.ledger.budget.spent, 25)
        XCTAssertEqual(tree.ledger.budget.reserved, 0)
        let (proceed, effects) = tree.ledger.consume(a.op, amount: 6)
        XCTAssertFalse(proceed)
        XCTAssertEqual(effects, [.resolve(a.claim, .budgetExceeded), .cancel(a.op)])
        XCTAssertEqual(tree.ledger.budget.spent, 25, "the refused consumption was not recorded")
        XCTAssertEqual(tree.ledger.totals.wastedCost, 25)
    }

    func testUnspentReservationIsReleasedOnCompletionAndOnDrain() throws {
        var tree = try makeTree()
        guard let a = accept(tree.ledger.submit(request(tree.viewA, resource: "a", cost: 50))),
              let b = accept(tree.ledger.submit(request(tree.viewB, resource: "b", cost: 40))) else { return }
        _ = tree.ledger.consume(a.op, amount: 20)
        _ = tree.ledger.finish(a.op, .success)
        XCTAssertEqual(tree.ledger.budget.reserved, 40)
        _ = tree.ledger.consume(b.op, amount: 5)
        _ = try tree.ledger.closeOwner(tree.viewB)
        XCTAssertEqual(tree.ledger.budget.reserved, 35, "draining work still holds its reservation")
        _ = tree.ledger.finish(b.op, .success)
        XCTAssertEqual(tree.ledger.budget.reserved, 0)
        XCTAssertEqual(tree.ledger.budget.spent, 25)
        XCTAssertEqual(tree.ledger.budget.available, 100_000 - 25)
    }

    func testTokenBudgetEdgeCases() {
        var budget = TokenBudget(capacity: -5)
        XCTAssertEqual(budget.capacity, 0)
        XCTAssertTrue(budget.reserve(0))
        XCTAssertFalse(budget.reserve(1))
        XCTAssertFalse(budget.reserve(-1))
        var big = TokenBudget(capacity: Int.max)
        XCTAssertTrue(big.reserve(Int.max))
        XCTAssertEqual(big.available, 0)
        XCTAssertFalse(big.consume(1, againstReservation: 0).ok)
        XCTAssertTrue(big.consume(Int.max, againstReservation: Int.max).ok)
        XCTAssertEqual(big.spent, Int.max)
        XCTAssertFalse(big.consume(-3, againstReservation: 0).ok)
        big.release(-10)
        XCTAssertEqual(big.reserved, 0)
    }
}

final class BoundsTests: XCTestCase {
    func testSaturatingArithmeticNeverTraps() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.remaining(3, minus: 10), 0)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    func testRingBufferKeepsNewestInOrder() {
        var ring = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(ring.elements, [])
        for value in 1...7 { ring.append(value) }
        XCTAssertEqual(ring.elements, [5, 6, 7])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(RingBuffer<Int>(capacity: Int.max).capacity, RingBuffer<Int>.maxCapacity)
        let huge = OwnershipLedger(configuration: .init(lanes: [:], budgetCapacity: 1,
                                                        historyCapacity: Int.max, eventCapacity: Int.max))
        XCTAssertEqual(huge.history.capacity, RingBuffer<OperationRecord>.maxCapacity)
        var tiny = RingBuffer<Int>(capacity: 0)
        tiny.append(1)
        tiny.append(2)
        XCTAssertEqual(tiny.elements, [2])
    }

    func testHistoryAndEventsAreBounded() throws {
        var tree = try makeTree()
        for index in 0..<50 {
            guard let a = accept(tree.ledger.submit(request(tree.viewA, resource: "r\(index)"))) else { return }
            _ = tree.ledger.finish(a.op, .success)
        }
        XCTAssertEqual(tree.ledger.history.count, 8)
        XCTAssertEqual(tree.ledger.events.count, 16)
        XCTAssertEqual(tree.ledger.history.elements.last?.resource, ResourceKey("r49"))
        XCTAssertEqual(tree.ledger.totals.completed, 50)
        XCTAssertEqual(tree.ledger.operationCount, 0)
        XCTAssertEqual(tree.ledger.claimCount, 0)
    }

    func testLaneLimitsClamp() {
        let limits = LaneLimits(maxConcurrent: 0, maxQueued: -4)
        XCTAssertEqual(limits.maxConcurrent, 1)
        XCTAssertEqual(limits.maxQueued, 0)
    }
}
