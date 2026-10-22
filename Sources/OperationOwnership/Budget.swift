/// Overflow-proof arithmetic for every counter the runtime keeps.
///
/// Ceilings are derived from `Int.max`, never from a 64-bit literal, so the
/// same code is correct where `Int` is 32 bits wide (watchOS arm64_32).
enum Saturating {
    static func add(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        if overflow { return b > 0 ? Int.max : Int.min }
        return value
    }

    static func subtract(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        if overflow { return b > 0 ? Int.min : Int.max }
        return value
    }

    static func multiply(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        if overflow { return (a < 0) == (b < 0) ? Int.max : Int.min }
        return value
    }

    /// `a - b`, floored at zero. Used wherever a negative result would mean a bug.
    static func remaining(_ a: Int, minus b: Int) -> Int { max(0, subtract(a, b)) }
}

/// A reserve → settle cost ledger.
///
/// Invariant (tested): `0 ≤ reserved`, `0 ≤ spent`, `reserved + spent ≤ capacity`.
/// Admission reserves an estimate; consumption converts reservation into spend;
/// ending an operation releases whatever it reserved but did not spend.
/// Over-consumption is first covered from free capacity and otherwise refused —
/// the budget never goes negative, so "available" is always an honest number.
public struct TokenBudget: Equatable, Sendable {
    public let capacity: Int
    public private(set) var reserved: Int = 0
    public private(set) var spent: Int = 0

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public var available: Int {
        Saturating.remaining(capacity, minus: Saturating.add(reserved, spent))
    }

    /// Reserve `amount` if it fits. Negative amounts are refused, not clamped.
    mutating func reserve(_ amount: Int) -> Bool {
        guard amount >= 0, amount <= available else { return false }
        reserved = Saturating.add(reserved, amount)
        return true
    }

    /// Convert `amount` of an operation's reservation into spend. If the
    /// operation has outrun its reservation, the overage is drawn from free
    /// capacity; returns `false` (and changes nothing) when that is impossible.
    mutating func consume(_ amount: Int, againstReservation held: Int) -> (ok: Bool, fromReservation: Int) {
        guard amount >= 0 else { return (false, 0) }
        let fromHeld = min(amount, max(0, held))
        let overage = Saturating.subtract(amount, fromHeld)
        guard overage <= available else { return (false, 0) }
        reserved = Saturating.remaining(reserved, minus: fromHeld)
        spent = Saturating.add(spent, amount)
        return (true, fromHeld)
    }

    /// Release an unspent reservation back to the pool.
    mutating func release(_ amount: Int) {
        guard amount > 0 else { return }
        reserved = Saturating.remaining(reserved, minus: amount)
    }
}

/// A fixed-capacity FIFO that silently drops the oldest element.
/// Used for history and the event log so neither can grow without bound.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    /// Hard ceiling on capacity: these buffers are for inspection, not storage,
    /// and an unbounded request (e.g. `Int.max`) must not be able to allocate.
    public static var maxCapacity: Int { 65_536 }

    public init(capacity: Int) {
        self.capacity = min(max(1, capacity), Self.maxCapacity)
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else if storage.indices.contains(head) {
            storage[head] = element
            head = (head + 1) % capacity // capacity >= 1, so the modulus is never zero
        }
    }

    /// Oldest first.
    public var elements: [Element] {
        guard storage.count == capacity, head > 0, head < storage.count else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var count: Int { storage.count }
}
