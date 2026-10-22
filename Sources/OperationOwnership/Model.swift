// The vocabulary of the runtime. Every piece of work declares four things
// before it picks a mechanism: its intent, its owner, the resource it touches,
// and how long it is allowed to outlive the code that asked for it.

/// The rungs of the ownership ladder, narrowest first.
///
/// An owner may only nest under an owner of a strictly *wider* kind, so the
/// tree always reads view → flow → session → account → app from leaf to root
/// (levels may be skipped, never inverted).
public enum ScopeKind: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case view = 0
    case flow = 1
    case session = 2
    case account = 3
    case app = 4

    public static func < (lhs: ScopeKind, rhs: ScopeKind) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .view: return "view"
        case .flow: return "flow"
        case .session: return "session"
        case .account: return "account"
        case .app: return "app"
        }
    }
}

/// Opaque, monotonically issued identifiers. They are never reused within a
/// ledger, so a stale id held by a finished task can never alias new work.
public struct OwnerID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
    public var description: String { "O\(raw)" }
}

public struct OperationID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
    public var description: String { "op\(raw)" }
}

public struct ClaimID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
    public var description: String { "c\(raw)" }
}

/// What the work touches. Two requests with the same key are candidates for
/// de-duplication, replacement or serialisation, depending on `Sharing`.
public struct ResourceKey: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// A concurrency class ("llm", "network", "disk"). Each lane has its own
/// admission limits, so a burst of thumbnails can never starve a generation.
public struct Lane: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public static func < (lhs: Lane, rhs: Lane) -> Bool { lhs.name < rhs.name }
    public var description: String { name }
}

public struct LaneLimits: Hashable, Sendable {
    /// Upper bound on operations that are running *or still draining after a
    /// cancel*. Clamped to at least 1.
    public let maxConcurrent: Int
    /// Upper bound on operations waiting for a lane slot or for their resource.
    /// Clamped to at least 0. This is the backpressure valve.
    public let maxQueued: Int

    public init(maxConcurrent: Int, maxQueued: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxQueued = max(0, maxQueued)
    }
}

/// How long work may outlive the code that requested it.
public enum Lifetime: Hashable, Sendable, CustomStringConvertible {
    /// Structured: the claim dies with its requesting owner *or* with the
    /// awaiting caller, whichever comes first. This is `.task` semantics.
    case owner
    /// The caller may leave; the nearest enclosing owner of at least this kind
    /// keeps the work alive (e.g. a generation owned by the session, not the screen).
    case scope(ScopeKind)
    /// Never cancelled by ownership. Reserved for work whose side effect must
    /// land (an upload, a receipt write). Counted as `durable`, never as waste.
    case mustFinish

    public var description: String {
        switch self {
        case .owner: return "owner"
        case .scope(let kind): return "scope(\(kind))"
        case .mustFinish: return "mustFinish"
        }
    }
}

/// What happens when a request names a resource that already has work in flight.
public enum Sharing: Hashable, Sendable, CustomStringConvertible {
    /// Join the newest in-flight operation for the resource. One execution, many claims.
    case coalesce
    /// Latest wins: supersede existing claims and start fresh (search-as-you-type).
    /// The new work starts once a superseded *running* task has drained.
    /// Refused with `.resourcePinned` if the existing work holds a `mustFinish` claim.
    case replace
    /// Queue behind existing work for the resource (per-resource FIFO).
    case serialize
    /// Refuse with `.resourceBusy` if anything is in flight for the resource.
    case rejectIfBusy
    /// Ignore the resource for sharing purposes; always a new operation.
    case independent

    public var description: String {
        switch self {
        case .coalesce: return "coalesce"
        case .replace: return "replace"
        case .serialize: return "serialize"
        case .rejectIfBusy: return "rejectIfBusy"
        case .independent: return "independent"
        }
    }
}

public enum Priority: Int, Comparable, Sendable, CaseIterable {
    case background = 0
    case normal = 1
    case userInitiated = 2

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The declaration a caller makes before any mechanism is chosen.
public struct OperationRequest: Sendable, Equatable {
    public var intent: String
    public var owner: OwnerID
    public var resource: ResourceKey?
    public var lane: Lane
    public var lifetime: Lifetime
    public var sharing: Sharing
    public var priority: Priority
    /// Tokens (or any cost unit) reserved from the budget at admission.
    /// Coalesced claims reserve nothing: joining is free by design.
    public var costEstimate: Int

    public init(
        intent: String,
        owner: OwnerID,
        resource: ResourceKey? = nil,
        lane: Lane,
        lifetime: Lifetime = .owner,
        sharing: Sharing = .independent,
        priority: Priority = .normal,
        costEstimate: Int = 0
    ) {
        self.intent = intent
        self.owner = owner
        self.resource = resource
        self.lane = lane
        self.lifetime = lifetime
        self.sharing = sharing
        self.priority = priority
        self.costEstimate = costEstimate
    }
}

/// Why a request was refused at the door. Every refusal is decided before any
/// work starts or any budget is held.
public enum Rejection: Hashable, Sendable, CustomStringConvertible {
    case unknownOwner
    case unknownLane
    case invalidEstimate
    case overloaded
    case resourceBusy
    case resourcePinned
    case budgetExhausted
    case callerCancelled

    public var description: String {
        switch self {
        case .unknownOwner: return "unknown or closed owner"
        case .unknownLane: return "lane not configured"
        case .invalidEstimate: return "negative cost estimate"
        case .overloaded: return "lane queue full"
        case .resourceBusy: return "resource busy"
        case .resourcePinned: return "resource held by must-finish work"
        case .budgetExhausted: return "budget exhausted"
        case .callerCancelled: return "caller already cancelled"
        }
    }
}

/// How a single claim ended. Exactly one resolution is emitted per claim that
/// has an awaiter; the ledger enforces this, the actor relies on it.
public enum ClaimResolution: Hashable, Sendable, CustomStringConvertible {
    case completed(OperationID)
    case failed(OperationID, String)
    case rejected(Rejection)
    /// A newer `.replace` request took the resource.
    case superseded
    /// The requesting owner closed. The work may continue if a wider scope owns it.
    case requesterClosed
    /// The awaiting caller's task was cancelled.
    case callerCancelled
    /// The operation consumed more than it reserved and the budget could not cover it.
    case budgetExceeded

    public var description: String {
        switch self {
        case .completed(let id): return "completed(\(id))"
        case .failed(let id, let reason): return "failed(\(id), \(reason))"
        case .rejected(let rejection): return "rejected(\(rejection))"
        case .superseded: return "superseded"
        case .requesterClosed: return "requesterClosed"
        case .callerCancelled: return "callerCancelled"
        case .budgetExceeded: return "budgetExceeded"
        }
    }
}

/// Instructions the pure ledger hands to whatever executes work.
/// Effects are emitted in the order they must be applied: resolutions for an
/// ending operation always precede the starts it unblocks.
public enum LedgerEffect: Hashable, Sendable, CustomStringConvertible {
    case start(OperationID)
    case cancel(OperationID)
    case resolve(ClaimID, ClaimResolution)

    public var description: String {
        switch self {
        case .start(let id): return "start \(id)"
        case .cancel(let id): return "cancel \(id)"
        case .resolve(let claim, let resolution): return "resolve \(claim) → \(resolution)"
        }
    }
}

public enum OwnerError: Error, Hashable, Sendable {
    case unknownParent
    case invalidNesting(child: ScopeKind, parent: ScopeKind)
    case capacityReached
    case unknownOwner
    case cannotCloseRoot
}

/// Where the value of a finished operation went.
public enum Delivery: String, Hashable, Sendable {
    /// At least one awaiting requester received the value.
    case delivered
    /// Nobody was awaiting, but a live owning scope below the app root still
    /// owned the work. The center does not cache values; the work's own side
    /// effect (writing into a session-level store) is the hand-off.
    case retained
    /// Nobody was waiting, but a `mustFinish` claim declared the side effect essential.
    case durable
    /// Completed with no live requester and no owning scope below the app root:
    /// the classic fire-and-forget `Task {}` outcome. Its cost is waste.
    case orphaned
    /// Cancelled or failed; there was no value to deliver.
    case none
}
