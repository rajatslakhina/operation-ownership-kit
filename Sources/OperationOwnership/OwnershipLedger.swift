/// The functional core of the runtime: a deterministic, synchronous state
/// machine that decides *what* should happen. It never spawns a task, never
/// sleeps and never reads a clock; it returns `LedgerEffect`s and lets an
/// executor (the `OperationCenter` actor, or the virtual-time `OwnershipLab`)
/// carry them out. That split is what makes every ordering guarantee below
/// testable without a single `Task.sleep`.
///
/// Guarantees (each is pinned by tests, and the checkers in `LedgerAudit` /
/// `auditResourceQueues()` are themselves shown to fail on broken input):
/// 1. **Ownership is the only cancellation authority.** An operation is
///    cancelled exactly when its last live claim goes away — never because one
///    of several requesters left.
/// 2. **One resolution per awaiting claim.** A claim is resolved at most once;
///    claims nobody awaits are never resolved again.
/// 3. **Limits bound real work.** A cancelled operation keeps its lane slot
///    *and* its place at the head of its resource queue while it drains, so
///    `maxConcurrent` and per-resource exclusivity bound running tasks, not
///    bookkeeping; no batch ever starts work it also cancels.
/// 4. **Bounded memory.** Owners, queued operations, claims per operation,
///    history and events are all capped.
/// 5. **Budget never goes negative.** See `TokenBudget`.
public struct OwnershipLedger: Sendable {

    public struct Configuration: Sendable {
        public var lanes: [Lane: LaneLimits]
        public var budgetCapacity: Int
        public var maxOwners: Int
        public var historyCapacity: Int
        public var eventCapacity: Int
        /// Cap on claims attached to one operation (awaiting and detached alike).
        /// A long session-scoped stream accumulates one detached claim per
        /// screen visit; past this cap further joiners are refused `.overloaded`.
        public var maxClaimsPerOperation: Int

        public init(
            lanes: [Lane: LaneLimits],
            budgetCapacity: Int,
            maxOwners: Int = 1_024,
            historyCapacity: Int = 128,
            eventCapacity: Int = 256,
            maxClaimsPerOperation: Int = 64
        ) {
            self.lanes = lanes
            self.budgetCapacity = budgetCapacity
            self.maxOwners = max(1, maxOwners)
            self.historyCapacity = historyCapacity
            self.eventCapacity = eventCapacity
            self.maxClaimsPerOperation = max(1, maxClaimsPerOperation)
        }
    }

    public enum OperationState: String, Sendable, Hashable {
        /// Admitted, but another operation holds the resource (`.serialize`).
        case waitingOnResource
        /// Eligible, waiting for a lane slot.
        case queued
        case running
        /// Cancelled; still holds its lane slot until the executor acknowledges.
        case draining
    }

    public enum FinishResult: Sendable, Hashable {
        case success
        case failure(String)
    }

    public enum SubmitOutcome: Sendable, Hashable {
        case accepted(claim: ClaimID, operation: OperationID, joined: Bool, effects: [LedgerEffect])
        case rejected(Rejection)
    }

    struct OwnerNode: Sendable {
        let id: OwnerID
        let kind: ScopeKind
        let label: String
        let parent: OwnerID?
        var children: [OwnerID] = []
    }

    struct Claim: Sendable {
        let id: ClaimID
        let operation: OperationID
        let requester: OwnerID
        /// Captured at claim time so inspectors can still name a closed requester.
        let requesterLabel: String
        /// `nil` means pinned (`.mustFinish`): ownership can never release it.
        let anchor: OwnerID?
        let lifetime: Lifetime
        var awaiting: Bool
    }

    struct Operation: Sendable {
        let id: OperationID
        let intent: String
        let resource: ResourceKey?
        let lane: Lane
        var state: OperationState
        var priority: Priority
        var claims: [ClaimID]
        var claimsEverJoined: Int
        var reservedRemaining: Int
        var consumed: Int
    }

    // MARK: State

    public let configuration: Configuration
    public let root: OwnerID
    public private(set) var budget: TokenBudget
    public private(set) var totals = LedgerTotals()
    public private(set) var history: RingBuffer<OperationRecord>
    public private(set) var events: RingBuffer<LedgerEvent>

    private var owners: [OwnerID: OwnerNode] = [:]
    private var claims: [ClaimID: Claim] = [:]
    private var operations: [OperationID: Operation] = [:]
    /// Per-resource FIFO of non-draining operations. The head is eligible for a
    /// lane; everything behind it is `.waitingOnResource`.
    private var resourceQueues: [ResourceKey: [OperationID]] = [:]

    /// Resources and lanes whose queues changed during the current call.
    /// Pumped exactly once, after every release in the call has been applied.
    private var dirtyResources: Set<ResourceKey> = []
    private var dirtyLanes: Set<Lane> = []

    private var nextOwner: UInt64 = 1
    private var nextOperation: UInt64 = 1
    private var nextClaim: UInt64 = 1
    private var nextEvent: UInt64 = 1

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.budget = TokenBudget(capacity: configuration.budgetCapacity)
        self.history = RingBuffer(capacity: configuration.historyCapacity)
        self.events = RingBuffer(capacity: configuration.eventCapacity)
        let rootID = OwnerID(raw: 0)
        self.root = rootID
        owners[rootID] = OwnerNode(id: rootID, kind: .app, label: "app", parent: nil)
    }

    // MARK: Owners

    public mutating func openOwner(_ kind: ScopeKind, label: String, parent: OwnerID) throws(OwnerError) -> OwnerID {
        guard let parentNode = owners[parent] else { throw .unknownParent }
        guard kind < parentNode.kind else { throw .invalidNesting(child: kind, parent: parentNode.kind) }
        guard owners.count < configuration.maxOwners else { throw .capacityReached }
        let id = OwnerID(raw: nextOwner)
        nextOwner &+= 1 // Wrapping, never trapping: 2^64 ids at 1e9/s is ~584 years.
        owners[id] = OwnerNode(id: id, kind: kind, label: label, parent: parent)
        owners[parent]?.children.append(id)
        log(.ownerOpened, "\(kind) \(label) (\(id)) under \(parentNode.label)")
        return id
    }

    /// Close an owner and its whole subtree. Requesters inside the subtree stop
    /// awaiting; claims *anchored* inside it are released; work anchored in a
    /// wider live scope, or pinned, keeps running.
    public mutating func closeOwner(_ id: OwnerID) throws(OwnerError) -> [LedgerEffect] {
        guard id != root else { throw .cannotCloseRoot }
        guard let node = owners[id] else { throw .unknownOwner }
        let subtree = collectSubtree(id)
        var effects: [LedgerEffect] = []

        for claimID in claims.keys.sorted() {
            guard let claim = claims[claimID] else { continue }
            if subtree.contains(claim.requester), claim.awaiting {
                claims[claimID]?.awaiting = false
                effects.append(.resolve(claimID, .requesterClosed))
            }
            if let anchor = claim.anchor, subtree.contains(anchor) {
                releaseClaim(claimID, resolution: nil, reason: "\(node.label) closed", effects: &effects)
            }
        }

        if let parent = node.parent {
            owners[parent]?.children.removeAll { $0 == id }
        }
        for member in subtree { owners[member] = nil }
        log(.ownerClosed, "\(node.kind) \(node.label) (\(id)) closed with \(subtree.count - 1) descendant(s)")
        flushPumps(&effects)
        return effects
    }

    public func isOpen(_ id: OwnerID) -> Bool { owners[id] != nil }

    public func label(of id: OwnerID) -> String? { owners[id]?.label }

    // MARK: Submission

    public mutating func submit(_ request: OperationRequest) -> SubmitOutcome {
        totals.submitted = Saturating.add(totals.submitted, 1)
        guard owners[request.owner] != nil else { return reject(request, .unknownOwner) }
        guard let limits = configuration.lanes[request.lane] else { return reject(request, .unknownLane) }
        guard request.costEstimate >= 0 else { return reject(request, .invalidEstimate) }

        var effects: [LedgerEffect] = []
        var supersede: [OperationID] = []
        var waitsOnResource = false

        if let resource = request.resource, request.sharing != .independent,
           let queue = resourceQueues[resource], !queue.isEmpty {
            // A draining operation stays at the head of its resource queue until
            // its task acknowledges, so a resource is never worked on by two
            // non-waiting operations at once — even while one is winding down.
            let holdsResource = queue.contains { operations[$0]?.state == .draining }
            switch request.sharing {
            case .coalesce:
                if let target = queue.last(where: { operations[$0].map { $0.state != .draining } ?? false }) {
                    guard (operations[target]?.claims.count ?? 0) < configuration.maxClaimsPerOperation else {
                        return reject(request, .overloaded)
                    }
                    return join(target, request: request)
                }
                waitsOnResource = holdsResource
            case .rejectIfBusy:
                return reject(request, .resourceBusy)
            case .replace:
                let victims = queue.filter { operations[$0].map { $0.state != .draining } ?? false }
                let pinned = victims.contains { opID in
                    (operations[opID]?.claims ?? []).contains { claims[$0]?.anchor == nil }
                }
                if pinned { return reject(request, .resourcePinned) }
                supersede = victims
                // Running victims become draining and keep the resource until they stop.
                waitsOnResource = queue.contains {
                    let state = operations[$0]?.state
                    return state == .running || state == .draining
                }
            case .serialize:
                waitsOnResource = true
            case .independent:
                break
            }
        }

        // Admission is checked against the *current* state, before anything is
        // superseded. A replace that would only fit after its victims released
        // their resources is refused rather than half-applied: never cancel
        // work you cannot replace.
        let running = count(in: request.lane) { $0 == .running || $0 == .draining }
        let waiting = count(in: request.lane) { $0 == .queued || $0 == .waitingOnResource }
        let startsNow = !waitsOnResource && running < limits.maxConcurrent
        if !startsNow, waiting >= limits.maxQueued { return reject(request, .overloaded) }
        guard budget.reserve(request.costEstimate) else { return reject(request, .budgetExhausted) }

        let opID = OperationID(raw: nextOperation)
        nextOperation &+= 1
        log(.submitted, "\(request.intent) → \(opID) [\(request.lane), \(request.lifetime), \(request.sharing)]")

        for victim in supersede {
            supersedeOperation(victim, effects: &effects)
        }

        let claimID = makeClaim(for: request, operation: opID)
        operations[opID] = Operation(
            id: opID,
            intent: request.intent,
            resource: request.sharing == .independent ? nil : request.resource,
            lane: request.lane,
            state: waitsOnResource ? .waitingOnResource : .queued,
            priority: request.priority,
            claims: [claimID],
            claimsEverJoined: 1,
            reservedRemaining: request.costEstimate,
            consumed: 0
        )
        if let resource = request.resource, request.sharing != .independent {
            resourceQueues[resource, default: []].append(opID)
        }
        flushPumps(&effects)
        pumpLane(request.lane, effects: &effects)
        return .accepted(claim: claimID, operation: opID, joined: false, effects: effects)
    }

    /// The awaiting caller went away (its task was cancelled). Structured
    /// (`.owner`) claims die with their caller; wider lifetimes keep the work
    /// alive for the scope that owns it.
    public mutating func detach(_ claimID: ClaimID) -> [LedgerEffect] {
        guard let claim = claims[claimID] else { return [] }
        var effects: [LedgerEffect] = []
        if claim.awaiting {
            claims[claimID]?.awaiting = false
            effects.append(.resolve(claimID, .callerCancelled))
        }
        if claim.lifetime == .owner {
            releaseClaim(claimID, resolution: nil, reason: "caller cancelled", effects: &effects)
        } else {
            log(.detached, "\(claimID) detached; \(claim.operation) kept alive by \(claim.lifetime)")
        }
        flushPumps(&effects)
        return effects
    }

    // MARK: Execution feedback

    /// Record cost as it is incurred (e.g. streamed tokens). Returns whether
    /// the work should continue. Work that is not `.running` must stop.
    public mutating func consume(_ operationID: OperationID, amount: Int) -> (proceed: Bool, effects: [LedgerEffect]) {
        guard let op = operations[operationID], op.state == .running, amount >= 0 else { return (false, []) }
        let result = budget.consume(amount, againstReservation: op.reservedRemaining)
        if result.ok {
            operations[operationID]?.consumed = Saturating.add(op.consumed, amount)
            operations[operationID]?.reservedRemaining = Saturating.remaining(op.reservedRemaining, minus: result.fromReservation)
            return (true, [])
        }
        var effects: [LedgerEffect] = []
        for claimID in op.claims {
            if claims[claimID]?.awaiting == true { effects.append(.resolve(claimID, .budgetExceeded)) }
            claims[claimID] = nil
        }
        operations[operationID]?.claims = []
        log(.budgetExceeded, "\(operationID) outran its reservation; budget could not cover \(amount)")
        cancelOperation(operationID, reason: "budget exceeded", effects: &effects)
        flushPumps(&effects)
        return (false, effects)
    }

    /// The executor reports that work stopped. Stale reports (for operations
    /// that never started or are already gone) are ignored, so a slow task can
    /// never corrupt the ledger after it was cancelled.
    public mutating func finish(_ operationID: OperationID, _ result: FinishResult) -> [LedgerEffect] {
        guard let op = operations[operationID] else { return [] }
        var effects: [LedgerEffect] = []
        switch op.state {
        case .waitingOnResource, .queued:
            return []
        case .draining:
            budget.release(op.reservedRemaining)
            removeFromResourceQueue(op)
            operations[operationID] = nil
            log(.drained, "\(operationID) drained; lane slot and resource released")
            if let resource = op.resource { pumpResource(resource, effects: &effects) }
        case .running:
            let delivery: Delivery
            switch result {
            case .success:
                delivery = deliveryFor(op)
                for claimID in op.claims where claims[claimID]?.awaiting == true {
                    effects.append(.resolve(claimID, .completed(operationID)))
                }
            case .failure(let reason):
                delivery = .none
                for claimID in op.claims where claims[claimID]?.awaiting == true {
                    effects.append(.resolve(claimID, .failed(operationID, reason)))
                }
            }
            for claimID in op.claims { claims[claimID] = nil }
            removeFromResourceQueue(op)
            budget.release(op.reservedRemaining)
            operations[operationID] = nil
            record(op, outcome: {
                if case .failure(let reason) = result { return .failed(reason) }
                return .completed(delivery)
            }())
            if let resource = op.resource { pumpResource(resource, effects: &effects) }
        }
        flushPumps(&effects)
        pumpLane(op.lane, effects: &effects)
        return effects
    }

    // MARK: Inspection

    public func state(of id: OperationID) -> OperationState? { operations[id]?.state }

    public func priority(of id: OperationID) -> Priority? { operations[id]?.priority }

    public func liveClaimCount(of id: OperationID) -> Int { operations[id]?.claims.count ?? 0 }

    public var runningOperations: [OperationID] {
        operations.values.filter { $0.state == .running }.map(\.id).sorted()
    }

    public var drainingOperations: [OperationID] {
        operations.values.filter { $0.state == .draining }.map(\.id).sorted()
    }

    /// The per-resource exclusivity invariant: in every resource queue, only the
    /// head may be queued, running or draining; everything behind it is
    /// `.waitingOnResource`; every entry is a live operation for that resource.
    public func auditResourceQueues() -> [LedgerAudit.Violation] {
        var violations: [LedgerAudit.Violation] = []
        for resource in resourceQueues.keys.sorted(by: { $0.raw < $1.raw }) {
            let queue = resourceQueues[resource] ?? []
            if queue.isEmpty { violations.append(.init(message: "\(resource): empty queue retained")) }
            for (index, id) in queue.enumerated() {
                guard let op = operations[id] else {
                    violations.append(.init(message: "\(resource): \(id) is queued but gone"))
                    continue
                }
                if op.resource != resource {
                    violations.append(.init(message: "\(resource): \(id) belongs to \(op.resource?.raw ?? "no resource")"))
                }
                if index > 0, op.state != .waitingOnResource {
                    violations.append(.init(message: "\(resource): \(id) is \(op.state.rawValue) behind the head"))
                }
                if index == 0, op.state == .waitingOnResource {
                    violations.append(.init(message: "\(resource): head \(id) is waiting on its own resource"))
                }
            }
        }
        return violations
    }

    public var operationCount: Int { operations.count }
    public var ownerCount: Int { owners.count }
    public var claimCount: Int { claims.count }

    public func snapshot() -> OwnershipSnapshot {
        var rows: [OwnershipSnapshot.OwnerRow] = []
        func walk(_ id: OwnerID, depth: Int) {
            guard let node = owners[id] else { return }
            let requested = claims.values.filter { $0.requester == id }.count
            let anchored = claims.values.filter { $0.anchor == id }.count
            rows.append(.init(id: id, kind: node.kind, label: node.label, depth: depth,
                              requestedClaims: requested, anchoredClaims: anchored))
            for child in node.children.sorted() { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)

        let ops = operations.values.sorted { $0.id < $1.id }.map { op in
            OwnershipSnapshot.OperationRow(
                id: op.id, intent: op.intent, resource: op.resource, lane: op.lane, state: op.state,
                priority: op.priority, consumed: op.consumed, reservedRemaining: op.reservedRemaining,
                claims: op.claims.compactMap { claimID in
                    guard let claim = claims[claimID] else { return nil }
                    return .init(id: claimID,
                                 requester: owners[claim.requester] != nil ? claim.requesterLabel : "\(claim.requesterLabel) (closed)",
                                 anchor: claim.anchor.map { owners[$0]?.label ?? "closed \($0)" } ?? "pinned",
                                 lifetime: claim.lifetime, awaiting: claim.awaiting)
                })
        }
        return OwnershipSnapshot(owners: rows, operations: ops, budget: budget, totals: totals)
    }

    // MARK: Internals

    private mutating func join(_ target: OperationID, request: OperationRequest) -> SubmitOutcome {
        let claimID = makeClaim(for: request, operation: target)
        operations[target]?.claims.append(claimID)
        if let op = operations[target] {
            operations[target]?.claimsEverJoined = Saturating.add(op.claimsEverJoined, 1)
            // Priority inheritance: a user-initiated joiner must not wait behind
            // the background request that happened to arrive first.
            if op.state != .running, request.priority > op.priority {
                operations[target]?.priority = request.priority
            }
        }
        totals.coalescedJoins = Saturating.add(totals.coalescedJoins, 1)
        log(.coalesced, "\(request.intent) joined \(target) (\(operations[target]?.claims.count ?? 0) claims)")
        return .accepted(claim: claimID, operation: target, joined: true, effects: [])
    }

    private mutating func makeClaim(for request: OperationRequest, operation: OperationID) -> ClaimID {
        let id = ClaimID(raw: nextClaim)
        nextClaim &+= 1
        claims[id] = Claim(id: id, operation: operation, requester: request.owner,
                           requesterLabel: owners[request.owner]?.label ?? "\(request.owner)",
                           anchor: anchor(for: request.lifetime, requester: request.owner),
                           lifetime: request.lifetime, awaiting: true)
        return id
    }

    /// `.owner` anchors to the requester; `.scope(k)` to the nearest enclosing
    /// owner of at least kind `k` (the root always qualifies); `.mustFinish` pins.
    func anchor(for lifetime: Lifetime, requester: OwnerID) -> OwnerID? {
        switch lifetime {
        case .owner:
            return requester
        case .mustFinish:
            return nil
        case .scope(let kind):
            var cursor: OwnerID? = requester
            var hops = 0
            while let id = cursor, let node = owners[id], hops <= ScopeKind.allCases.count {
                if node.kind >= kind { return id }
                cursor = node.parent
                hops += 1 // Nesting is strictly widening, so depth ≤ number of kinds.
            }
            return root
        }
    }

    private mutating func releaseClaim(_ claimID: ClaimID, resolution: ClaimResolution?, reason: String, effects: inout [LedgerEffect]) {
        guard let claim = claims[claimID] else { return }
        if let resolution, claim.awaiting { effects.append(.resolve(claimID, resolution)) }
        claims[claimID] = nil
        guard var op = operations[claim.operation] else { return }
        op.claims.removeAll { $0 == claimID }
        operations[claim.operation] = op
        if op.claims.isEmpty {
            cancelOperation(op.id, reason: reason, effects: &effects)
        }
    }

    private mutating func supersedeOperation(_ opID: OperationID, effects: inout [LedgerEffect]) {
        guard let op = operations[opID] else { return }
        for claimID in op.claims {
            if claims[claimID]?.awaiting == true { effects.append(.resolve(claimID, .superseded)) }
            claims[claimID] = nil
        }
        operations[opID]?.claims = []
        cancelOperation(opID, reason: "superseded", effects: &effects)
    }

    private mutating func cancelOperation(_ opID: OperationID, reason: String, effects: inout [LedgerEffect]) {
        guard let op = operations[opID] else { return }
        switch op.state {
        case .draining:
            return
        case .waitingOnResource, .queued:
            removeFromResourceQueue(op)
            budget.release(op.reservedRemaining)
            operations[opID] = nil
            record(op, outcome: .cancelled(reason))
            log(.cancelled, "\(opID) cancelled before start (\(reason))")
            // Never pump mid-batch: a waiter promoted here could be started and
            // then cancelled by the next release in the same call.
            if let resource = op.resource { dirtyResources.insert(resource) }
            dirtyLanes.insert(op.lane)
        case .running:
            // Keeps its lane slot *and* its place at the head of the resource
            // queue until the executor acknowledges with `finish`.
            operations[opID]?.state = .draining
            effects.append(.cancel(opID))
            record(op, outcome: .cancelled(reason))
            log(.cancelled, "\(opID) cancelled while running (\(reason)); draining")
        }
    }

    private mutating func flushPumps(_ effects: inout [LedgerEffect]) {
        let resources = dirtyResources.sorted { $0.raw < $1.raw }
        let lanes = dirtyLanes.sorted()
        dirtyResources = []
        dirtyLanes = []
        for resource in resources { pumpResource(resource, effects: &effects) }
        for lane in lanes { pumpLane(lane, effects: &effects) }
    }

    private mutating func removeFromResourceQueue(_ op: Operation) {
        guard let resource = op.resource else { return }
        resourceQueues[resource]?.removeAll { $0 == op.id }
        if resourceQueues[resource]?.isEmpty == true { resourceQueues[resource] = nil }
    }

    private mutating func pumpResource(_ resource: ResourceKey, effects: inout [LedgerEffect]) {
        guard let head = resourceQueues[resource]?.first,
              let op = operations[head], op.state == .waitingOnResource else { return }
        operations[head]?.state = .queued
        pumpLane(op.lane, effects: &effects)
    }

    private mutating func pumpLane(_ lane: Lane, effects: inout [LedgerEffect]) {
        guard let limits = configuration.lanes[lane] else { return }
        while count(in: lane, where: { $0 == .running || $0 == .draining }) < limits.maxConcurrent {
            let candidates = operations.values.filter { $0.lane == lane && $0.state == .queued }
            guard let next = candidates.max(by: { lhs, rhs in
                lhs.priority != rhs.priority ? lhs.priority < rhs.priority : lhs.id > rhs.id
            }) else { return }
            operations[next.id]?.state = .running
            totals.started = Saturating.add(totals.started, 1)
            effects.append(.start(next.id))
            log(.started, "\(next.id) started on \(lane)")
        }
    }

    private func count(in lane: Lane, where predicate: (OperationState) -> Bool) -> Int {
        operations.values.reduce(0) { $1.lane == lane && predicate($1.state) ? $0 + 1 : $0 }
    }

    private func deliveryFor(_ op: Operation) -> Delivery {
        let live = op.claims.compactMap { claims[$0] }
        if live.contains(where: { $0.awaiting }) { return .delivered }
        if live.contains(where: { $0.anchor != nil && $0.anchor != root }) { return .retained }
        if live.contains(where: { $0.anchor == nil }) { return .durable }
        return .orphaned
    }

    private func collectSubtree(_ id: OwnerID) -> Set<OwnerID> {
        var result: Set<OwnerID> = []
        var stack = [id]
        while let next = stack.popLast() {
            guard result.insert(next).inserted, let node = owners[next] else { continue }
            stack.append(contentsOf: node.children)
        }
        return result
    }

    private mutating func reject(_ request: OperationRequest, _ rejection: Rejection) -> SubmitOutcome {
        totals.rejected = Saturating.add(totals.rejected, 1)
        log(.rejected, "\(request.intent) rejected: \(rejection)")
        return .rejected(rejection)
    }

    private mutating func record(_ op: Operation, outcome: OperationRecord.Outcome) {
        switch outcome {
        case .completed(let delivery):
            totals.completed = Saturating.add(totals.completed, 1)
            switch delivery {
            case .delivered: totals.delivered = Saturating.add(totals.delivered, 1)
            case .retained: totals.retained = Saturating.add(totals.retained, 1)
            case .durable: totals.durable = Saturating.add(totals.durable, 1)
            case .orphaned:
                totals.orphaned = Saturating.add(totals.orphaned, 1)
                totals.wastedCost = Saturating.add(totals.wastedCost, op.consumed)
            case .none: break
            }
        case .failed:
            totals.failed = Saturating.add(totals.failed, 1)
        case .cancelled:
            totals.cancelled = Saturating.add(totals.cancelled, 1)
            totals.wastedCost = Saturating.add(totals.wastedCost, op.consumed)
        }
        history.append(OperationRecord(id: op.id, intent: op.intent, resource: op.resource, lane: op.lane,
                                       outcome: outcome, claimsJoined: op.claimsEverJoined, consumed: op.consumed))
    }

    private mutating func log(_ kind: LedgerEvent.Kind, _ message: String) {
        events.append(LedgerEvent(sequence: nextEvent, kind: kind, message: message))
        nextEvent &+= 1
    }
}
