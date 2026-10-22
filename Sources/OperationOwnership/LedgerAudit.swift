/// Independent checkers for the ledger's invariants. They live in the library
/// (not the tests) so an app can run them in debug builds, and so the tests can
/// prove each checker *fails* on a deliberately broken input — a checker that
/// cannot fail is not a checker.
public enum LedgerAudit {

    public struct Violation: Equatable, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Checks an ordered stream of effects:
    /// - a claim is resolved at most once;
    /// - an operation is started at most once;
    /// - an operation is never started after it was cancelled;
    /// - an operation is never cancelled before it was started.
    public static func effects(_ stream: [LedgerEffect]) -> [Violation] {
        var resolved: Set<ClaimID> = []
        var started: Set<OperationID> = []
        var cancelled: Set<OperationID> = []
        var violations: [Violation] = []
        for effect in stream {
            switch effect {
            case .resolve(let claim, let resolution):
                if !resolved.insert(claim).inserted {
                    violations.append(.init(message: "\(claim) resolved twice (second: \(resolution))"))
                }
            case .start(let op):
                if cancelled.contains(op) { violations.append(.init(message: "\(op) started after cancel")) }
                if !started.insert(op).inserted { violations.append(.init(message: "\(op) started twice")) }
            case .cancel(let op):
                if !started.contains(op) { violations.append(.init(message: "\(op) cancelled before it started")) }
                if !cancelled.insert(op).inserted { violations.append(.init(message: "\(op) cancelled twice")) }
            }
        }
        return violations
    }

    /// Checks one batch of effects returned by a single ledger call: an
    /// operation must never be started and cancelled in the same batch. That
    /// would launch a real task nobody owns.
    public static func batch(_ effects: [LedgerEffect]) -> [Violation] {
        var started: Set<OperationID> = []
        var violations: [Violation] = []
        for effect in effects {
            switch effect {
            case .start(let op): started.insert(op)
            case .cancel(let op) where started.contains(op):
                violations.append(.init(message: "\(op) started and cancelled in one batch"))
            default: break
            }
        }
        return violations
    }

    /// Checks a snapshot against its lane limits:
    /// - running + draining ≤ `maxConcurrent` per lane;
    /// - queued + waiting ≤ `maxQueued` per lane;
    /// - every non-draining operation has at least one live claim;
    /// - every draining operation has none.
    public static func snapshot(_ snapshot: OwnershipSnapshot, lanes: [Lane: LaneLimits]) -> [Violation] {
        var violations: [Violation] = []
        let byLane = Dictionary(grouping: snapshot.operations, by: \.lane)
        for lane in byLane.keys.sorted() {
            let ops = byLane[lane] ?? []
            guard let limits = lanes[lane] else {
                violations.append(.init(message: "operations on unconfigured lane \(lane)"))
                continue
            }
            let active = ops.filter { $0.state == .running || $0.state == .draining }.count
            let waiting = ops.filter { $0.state == .queued || $0.state == .waitingOnResource }.count
            if active > limits.maxConcurrent {
                violations.append(.init(message: "\(lane): \(active) active > maxConcurrent \(limits.maxConcurrent)"))
            }
            if waiting > limits.maxQueued {
                violations.append(.init(message: "\(lane): \(waiting) waiting > maxQueued \(limits.maxQueued)"))
            }
        }
        for op in snapshot.operations {
            if op.state == .draining, !op.claims.isEmpty {
                violations.append(.init(message: "\(op.id) is draining but still has \(op.claims.count) claim(s)"))
            }
            if op.state != .draining, op.claims.isEmpty {
                violations.append(.init(message: "\(op.id) is \(op.state.rawValue) with no owner"))
            }
        }
        violations.append(contentsOf: budget(capacity: snapshot.budget.capacity,
                                             reserved: snapshot.budget.reserved,
                                             spent: snapshot.budget.spent))
        return violations
    }

    /// `0 ≤ reserved`, `0 ≤ spent`, `reserved + spent ≤ capacity`.
    public static func budget(capacity: Int, reserved: Int, spent: Int) -> [Violation] {
        var violations: [Violation] = []
        if reserved < 0 { violations.append(.init(message: "negative reservation \(reserved)")) }
        if spent < 0 { violations.append(.init(message: "negative spend \(spent)")) }
        let (total, overflow) = reserved.addingReportingOverflow(spent)
        if overflow || total > capacity {
            violations.append(.init(message: "reserved \(reserved) + spent \(spent) exceeds capacity \(capacity)"))
        }
        return violations
    }
}
