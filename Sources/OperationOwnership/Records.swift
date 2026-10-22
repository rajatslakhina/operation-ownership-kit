/// Lifetime counters. All increments saturate, so a long-lived process can
/// never trap on a statistic.
public struct LedgerTotals: Equatable, Sendable {
    public var submitted = 0
    public var rejected = 0
    public var started = 0
    public var coalescedJoins = 0
    public var completed = 0
    public var failed = 0
    public var cancelled = 0
    public var delivered = 0
    /// Completed with nobody awaiting, while a live non-root scope still owned
    /// the work. The center does not cache values: the work's own side effect
    /// (e.g. writing into a session store) is the hand-off.
    public var retained = 0
    public var durable = 0
    public var orphaned = 0
    /// Cost consumed by work that was cancelled, plus work that completed orphaned.
    /// Failed work is counted under `failed`, not here: a failure is a product
    /// problem, waste is an ownership problem.
    public var wastedCost = 0

    public init() {}
}

public struct OperationRecord: Equatable, Sendable, Identifiable {
    public enum Outcome: Equatable, Sendable {
        case completed(Delivery)
        case failed(String)
        case cancelled(String)
    }

    public let id: OperationID
    public let intent: String
    public let resource: ResourceKey?
    public let lane: Lane
    public let outcome: Outcome
    public let claimsJoined: Int
    public let consumed: Int
}

public struct LedgerEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case ownerOpened, ownerClosed, submitted, coalesced, rejected, started
        case detached, cancelled, drained, budgetExceeded
    }

    public let sequence: UInt64
    public let kind: Kind
    public let message: String
    public var id: UInt64 { sequence }
}

/// A point-in-time, value-typed picture of the ownership tree for inspectors.
public struct OwnershipSnapshot: Equatable, Sendable {
    public struct OwnerRow: Equatable, Sendable, Identifiable {
        public let id: OwnerID
        public let kind: ScopeKind
        public let label: String
        public let depth: Int
        /// Claims this owner asked for.
        public let requestedClaims: Int
        /// Claims whose lifetime this owner currently guarantees.
        public let anchoredClaims: Int
    }

    public struct ClaimRow: Equatable, Sendable, Identifiable {
        public let id: ClaimID
        public let requester: String
        public let anchor: String
        public let lifetime: Lifetime
        public let awaiting: Bool
    }

    public struct OperationRow: Equatable, Sendable, Identifiable {
        public let id: OperationID
        public let intent: String
        public let resource: ResourceKey?
        public let lane: Lane
        public let state: OwnershipLedger.OperationState
        public let priority: Priority
        public let consumed: Int
        public let reservedRemaining: Int
        public let claims: [ClaimRow]
    }

    public let owners: [OwnerRow]
    public let operations: [OperationRow]
    public let budget: TokenBudget
    public let totals: LedgerTotals
}
