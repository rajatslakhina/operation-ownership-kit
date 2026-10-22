/// Errors surfaced to a caller of `OperationCenter.perform`.
public enum OperationError: Error, Equatable, Sendable {
    case rejected(Rejection)
    case superseded
    case requesterClosed
    case callerCancelled
    case budgetExceeded
    case failed(String)
    /// Two requests coalesced on one resource key but expected different result
    /// types. Resource keys are a namespace; this is a programming error.
    case typeMismatch

    init(_ resolution: ClaimResolution) {
        switch resolution {
        case .completed: self = .failed("completed without a value")
        case .failed(_, let reason): self = .failed(reason)
        case .rejected(let rejection): self = .rejected(rejection)
        case .superseded: self = .superseded
        case .requesterClosed: self = .requesterClosed
        case .callerCancelled: self = .callerCancelled
        case .budgetExceeded: self = .budgetExceeded
        }
    }
}

/// Handed to running work so it can report cost (e.g. streamed tokens) and
/// learn whether it should stop. Holds the center weakly: a context that
/// outlives the center simply reports "stop".
public struct OperationContext: Sendable {
    public let operation: OperationID
    private weak var center: OperationCenter?

    init(operation: OperationID, center: OperationCenter) {
        self.operation = operation
        self.center = center
    }

    /// Record `amount` of cost. Throws `CancellationError` when the work no
    /// longer has an owner or has outrun the budget, so streaming loops can
    /// simply `try await context.consume(n)` per chunk.
    public func consume(_ amount: Int) async throws {
        guard let center else { throw CancellationError() }
        try await center.consume(operation, amount)
    }
}

/// The imperative shell around `OwnershipLedger`: it turns ledger effects into
/// real `Task`s, cancellations and continuation resumptions.
///
/// Reentrancy rule: no method mutates state across an `await`. Every public
/// entry point does all of its ledger work and effect application in a single
/// synchronous actor turn; the only suspension is the caller waiting on its
/// own continuation. Task completion re-enters through `taskFinished`, which is
/// again a single turn. That is why interleavings cannot tear the ledger.
public actor OperationCenter {
    public typealias Work = @Sendable (OperationContext) async throws -> any Sendable

    private var ledger: OwnershipLedger
    private var works: [OperationID: Work] = [:]
    private var tasks: [OperationID: Task<Void, Never>] = [:]
    private var waiters: [ClaimID: CheckedContinuation<any Sendable, any Error>] = [:]
    /// Resolutions that arrive before their waiter is installed. Defensive:
    /// with today's isolation inheritance there is no suspension between
    /// `submit` and installing the waiter, but correctness must not depend on that.
    private var early: [ClaimID: Result<any Sendable, OperationError>] = [:]
    private var completedValues: [OperationID: any Sendable] = [:]

    public init(configuration: OwnershipLedger.Configuration) {
        self.ledger = OwnershipLedger(configuration: configuration)
    }

    public var root: OwnerID { ledger.root }

    public func openOwner(_ kind: ScopeKind, label: String, parent: OwnerID) throws(OwnerError) -> OwnerID {
        try ledger.openOwner(kind, label: label, parent: parent)
    }

    public func closeOwner(_ id: OwnerID) throws(OwnerError) {
        let effects = try ledger.closeOwner(id)
        apply(effects)
    }

    public func snapshot() -> OwnershipSnapshot { ledger.snapshot() }

    public var recentEvents: [LedgerEvent] { ledger.events.elements }

    /// Declare the work, then let the ledger decide whether it runs, joins an
    /// existing execution, waits, or is refused.
    public func perform<T: Sendable>(
        _ request: OperationRequest,
        _ work: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        let value = try await performErased(request) { context in try await work(context) }
        guard let typed = value as? T else { throw OperationError.typeMismatch }
        return typed
    }

    private func performErased(_ request: OperationRequest, _ work: @escaping Work) async throws -> any Sendable {
        guard !Task.isCancelled else { throw OperationError.rejected(.callerCancelled) }
        switch ledger.submit(request) {
        case .rejected(let rejection):
            throw OperationError.rejected(rejection)
        case .accepted(let claim, let operation, let joined, let effects):
            if !joined { works[operation] = work }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any Sendable, any Error>) in
                    if let pending = early.removeValue(forKey: claim) {
                        continuation.resume(with: pending.mapError { $0 as any Error })
                    } else {
                        waiters[claim] = continuation
                    }
                    apply(effects)
                }
            } onCancel: {
                Task { [weak self] in await self?.callerCancelled(claim) }
            }
        }
    }

    func consume(_ operation: OperationID, _ amount: Int) throws {
        let (proceed, effects) = ledger.consume(operation, amount: amount)
        apply(effects)
        if !proceed { throw CancellationError() }
    }

    private func callerCancelled(_ claim: ClaimID) {
        apply(ledger.detach(claim))
    }

    private func taskFinished(_ operation: OperationID, _ result: Result<any Sendable, any Error>) {
        tasks[operation] = nil
        let finish: OwnershipLedger.FinishResult
        switch result {
        case .success(let value):
            completedValues[operation] = value
            finish = .success
        case .failure(let error):
            finish = .failure(String(describing: error))
        }
        apply(ledger.finish(operation, finish))
        completedValues[operation] = nil
    }

    private func apply(_ effects: [LedgerEffect]) {
        for effect in effects {
            switch effect {
            case .start(let operation):
                start(operation)
            case .cancel(let operation):
                tasks[operation]?.cancel()
            case .resolve(let claim, let resolution):
                resolve(claim, resolution)
            }
        }
        purgeFinishedWork()
    }

    private func start(_ operation: OperationID) {
        guard let work = works[operation] else {
            // Unreachable by construction (every new operation registers its
            // work before effects are applied); fail it rather than hang its claims.
            apply(ledger.finish(operation, .failure("no work registered")))
            return
        }
        let context = OperationContext(operation: operation, center: self)
        // The task's closure is released when it completes, and `tasks[operation]`
        // is cleared in `taskFinished`, so the actor ↔ task reference is never a
        // lasting cycle. `self` is captured weakly regardless.
        // Admission order is the ledger's job; execution priority follows it.
        let priority: TaskPriority = switch ledger.priority(of: operation) ?? .normal {
        case .background: .background
        case .normal: .medium
        case .userInitiated: .userInitiated
        }
        tasks[operation] = Task(priority: priority) { [weak self] in
            let result: Result<any Sendable, any Error>
            do { result = .success(try await work(context)) } catch { result = .failure(error) }
            await self?.taskFinished(operation, result)
        }
    }

    private func resolve(_ claim: ClaimID, _ resolution: ClaimResolution) {
        let outcome: Result<any Sendable, OperationError>
        if case .completed(let operation) = resolution, let value = completedValues[operation] {
            outcome = .success(value)
        } else {
            outcome = .failure(OperationError(resolution))
        }
        if let continuation = waiters.removeValue(forKey: claim) {
            continuation.resume(with: outcome.mapError { $0 as any Error })
        } else {
            early[claim] = outcome
        }
    }

    private func purgeFinishedWork() {
        for operation in works.keys where ledger.state(of: operation) == nil && tasks[operation] == nil {
            works[operation] = nil
        }
    }

    // MARK: Test and inspector hooks

    var pendingWorkCount: Int { works.count }
    var waiterCount: Int { waiters.count }
    var earlyCount: Int { early.count }
}
