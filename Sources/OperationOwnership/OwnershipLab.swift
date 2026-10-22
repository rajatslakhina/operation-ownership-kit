/// A deterministic, virtual-time harness that drives the *real* ledger through
/// a scripted user journey under three ownership strategies, so their costs can
/// be compared side by side. No clocks, no tasks, no randomness: the same
/// scenario always produces the same numbers, which is what lets the tests pin them.
///
/// Tick semantics: at each tick the lab (1) acknowledges operations that were
/// cancelled on the previous tick (they drain), (2) applies that tick's scripted
/// steps, then (3) advances every operation that was running at the start of
/// phase 3 by one tick of work.
public struct LabScenario: Identifiable, Hashable, Sendable {
    public enum Step: Hashable, Sendable {
        case open(String, ScopeKind, parent: String?)
        case close(String)
        case request(LabRequest)
    }

    public struct TimedStep: Hashable, Sendable {
        public let tick: Int
        public let step: Step
        public init(_ tick: Int, _ step: Step) {
            self.tick = tick
            self.step = step
        }
    }

    public let id: String
    public let title: String
    public let summary: String
    public let endTick: Int
    public let lanes: [Lane: LaneLimits]
    public let steps: [TimedStep]

    /// Upper bound on scripted length, so a scenario cannot allocate unbounded frames.
    public static let maxTicks = 240

    public init(id: String, title: String, summary: String, endTick: Int, lanes: [Lane: LaneLimits], steps: [TimedStep]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.endTick = min(max(0, endTick), Self.maxTicks)
        self.lanes = lanes
        self.steps = steps
    }
}

public struct LabRequest: Hashable, Sendable {
    public let owner: String
    public let intent: String
    public let resource: String
    public let lane: Lane
    /// The lifetime the *owned* strategy declares. The baselines ignore it.
    public let ownedLifetime: Lifetime
    public let ownedSharing: Sharing
    public let durationTicks: Int
    public let costPerTick: Int

    public init(owner: String, intent: String, resource: String, lane: Lane,
                ownedLifetime: Lifetime, ownedSharing: Sharing = .coalesce,
                durationTicks: Int, costPerTick: Int) {
        self.owner = owner
        self.intent = intent
        self.resource = resource
        self.lane = lane
        self.ownedLifetime = ownedLifetime
        self.ownedSharing = ownedSharing
        self.durationTicks = max(1, durationTicks)
        self.costPerTick = max(0, costPerTick)
    }
}

public enum LabStrategy: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Work tied to the view's `.task`: dies with the screen, never shared.
    case taskBound
    /// Unstructured `Task {}`: belongs to nobody (effectively the process), never shared.
    case fireAndForget
    /// Declared intent, owner, resource and lifetime, through the ledger.
    case owned

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .taskBound: return ".task-bound"
        case .fireAndForget: return "Task { } fire-and-forget"
        case .owned: return "Owned (OperationCenter)"
        }
    }

    func policy(for request: LabRequest) -> (Lifetime, Sharing) {
        switch self {
        case .taskBound: return (.owner, .independent)
        case .fireAndForget: return (.scope(.app), .independent)
        case .owned: return (request.ownedLifetime, request.ownedSharing)
        }
    }
}

public struct LabMetrics: Equatable, Sendable {
    public var executionsStarted = 0
    public var coalescedJoins = 0
    public var costSpent = 0
    public var costWasted = 0
    public var cancelled = 0
    public var orphanedCompletions = 0
    public var durableCompletions = 0
    /// Awaiting requesters that actually received a value.
    public var resultsDelivered = 0
    public var lastResultTick: Int?
    public var rejectedRequests = 0

    public init() {}
}

public struct LabFrame: Equatable, Sendable, Identifiable {
    public let tick: Int
    public let snapshot: OwnershipSnapshot
    public var id: Int { tick }
}

public struct LabRun: Equatable, Sendable, Identifiable {
    public let strategy: LabStrategy
    public let metrics: LabMetrics
    public let frames: [LabFrame]
    public let events: [LedgerEvent]
    public var id: LabStrategy { strategy }
}

public enum OwnershipLab {

    public static func compare(_ scenario: LabScenario) -> [LabRun] {
        LabStrategy.allCases.map { run(scenario, strategy: $0) }
    }

    public static func run(_ scenario: LabScenario, strategy: LabStrategy) -> LabRun {
        var ledger = OwnershipLedger(configuration: .init(
            lanes: scenario.lanes,
            budgetCapacity: Int.max / 2, // The lab measures cost; it does not ration it.
            historyCapacity: 64,
            eventCapacity: 512))
        var names: [String: OwnerID] = [:]
        var remaining: [OperationID: Int] = [:]
        var rate: [OperationID: Int] = [:]
        var metrics = LabMetrics()
        var frames: [LabFrame] = []
        frames.reserveCapacity(scenario.endTick + 1)

        func absorb(_ effects: [LedgerEffect], at tick: Int) {
            for case .resolve(_, .completed) in effects {
                metrics.resultsDelivered += 1
                metrics.lastResultTick = tick
            }
        }

        for tick in 0...scenario.endTick {
            // (1) Cancelled work acknowledges and releases its lane slot.
            for op in ledger.drainingOperations {
                absorb(ledger.finish(op, .success), at: tick)
                remaining[op] = nil
                rate[op] = nil
            }

            // (2) Scripted user journey.
            for timed in scenario.steps where timed.tick == tick {
                switch timed.step {
                case .open(let name, let kind, let parentName):
                    let parent = parentName.flatMap { names[$0] } ?? ledger.root
                    if let id = try? ledger.openOwner(kind, label: name, parent: parent) { names[name] = id }
                case .close(let name):
                    if let id = names[name], let effects = try? ledger.closeOwner(id) {
                        absorb(effects, at: tick)
                        names[name] = nil
                    }
                case .request(let request):
                    guard let owner = names[request.owner] else {
                        metrics.rejectedRequests += 1
                        continue
                    }
                    let (lifetime, sharing) = strategy.policy(for: request)
                    let outcome = ledger.submit(OperationRequest(
                        intent: request.intent, owner: owner, resource: ResourceKey(request.resource),
                        lane: request.lane, lifetime: lifetime, sharing: sharing,
                        costEstimate: Saturating.multiply(request.durationTicks, request.costPerTick)))
                    switch outcome {
                    case .rejected:
                        metrics.rejectedRequests += 1
                    case .accepted(_, let op, let joined, let effects):
                        if !joined {
                            remaining[op] = request.durationTicks
                            rate[op] = request.costPerTick
                        }
                        absorb(effects, at: tick)
                    }
                }
            }

            // (3) One tick of work for everything running right now.
            for op in ledger.runningOperations {
                guard let left = remaining[op], left > 0 else { continue }
                let (proceed, effects) = ledger.consume(op, amount: rate[op] ?? 0)
                absorb(effects, at: tick)
                guard proceed else { continue }
                if left <= 1 {
                    remaining[op] = nil
                    rate[op] = nil
                    absorb(ledger.finish(op, .success), at: tick)
                } else {
                    remaining[op] = left - 1
                }
            }

            frames.append(LabFrame(tick: tick, snapshot: ledger.snapshot()))
        }

        let totals = ledger.totals
        metrics.executionsStarted = totals.started
        metrics.coalescedJoins = totals.coalescedJoins
        metrics.costSpent = ledger.budget.spent
        metrics.costWasted = totals.wastedCost
        metrics.cancelled = totals.cancelled
        metrics.orphanedCompletions = totals.orphaned
        metrics.durableCompletions = totals.durable
        return LabRun(strategy: strategy, metrics: metrics, frames: frames, events: ledger.events.elements)
    }
}

// MARK: - Presets

public extension LabScenario {
    static let llm = Lane("llm")
    static let io = Lane("io")

    /// The flagship: a streaming generation, the user leaves the screen and comes back.
    static let navigateAway = LabScenario(
        id: "navigate-away",
        title: "Leave and return mid-generation",
        summary: "A reply streams at 40 tokens/tick for 12 ticks. The user leaves the screen at tick 4 and reopens it at tick 6.",
        endTick: 20,
        lanes: [llm: LaneLimits(maxConcurrent: 2, maxQueued: 4)],
        steps: [
            .init(0, .open("session", .session, parent: nil)),
            .init(0, .open("chat", .flow, parent: "session")),
            .init(0, .open("reply-screen#1", .view, parent: "chat")),
            .init(0, .request(.reply(owner: "reply-screen#1"))),
            .init(4, .close("reply-screen#1")),
            .init(6, .open("reply-screen#2", .view, parent: "chat")),
            .init(6, .request(.reply(owner: "reply-screen#2"))),
        ])

    /// Ownership must also *end* work: sign-out mid-stream, with a draft upload in flight.
    static let signOut = LabScenario(
        id: "sign-out",
        title: "Sign out mid-generation",
        summary: "A reply is streaming and a draft upload starts at tick 3. The user signs out at tick 5.",
        endTick: 16,
        lanes: [llm: LaneLimits(maxConcurrent: 2, maxQueued: 4), io: LaneLimits(maxConcurrent: 2, maxQueued: 4)],
        steps: [
            .init(0, .open("account", .account, parent: nil)),
            .init(0, .open("session", .session, parent: "account")),
            .init(0, .open("chat", .flow, parent: "session")),
            .init(0, .open("reply-screen", .view, parent: "chat")),
            .init(0, .request(.reply(owner: "reply-screen"))),
            .init(3, .request(LabRequest(owner: "reply-screen", intent: "Upload draft", resource: "draft:42",
                                         lane: io, ownedLifetime: .mustFinish, durationTicks: 4, costPerTick: 0))),
            .init(5, .close("account")),
        ])

    /// Three rows ask for the same summary at once on a single-slot model lane.
    static let burst = LabScenario(
        id: "burst",
        title: "Three rows, one summary",
        summary: "Three inbox rows request the summary of doc 7 at once, and row 3 also asks for doc 9. One model slot; 8 ticks at 25 tokens each.",
        endTick: 34,
        lanes: [llm: LaneLimits(maxConcurrent: 1, maxQueued: 4)],
        steps: [
            .init(0, .open("session", .session, parent: nil)),
            .init(0, .open("inbox", .flow, parent: "session")),
            .init(0, .open("row-1", .view, parent: "inbox")),
            .init(0, .open("row-2", .view, parent: "inbox")),
            .init(0, .open("row-3", .view, parent: "inbox")),
            .init(0, .request(.summary(owner: "row-1", doc: 7))),
            .init(0, .request(.summary(owner: "row-2", doc: 7))),
            .init(0, .request(.summary(owner: "row-3", doc: 7))),
            .init(0, .request(.summary(owner: "row-3", doc: 9))),
        ])

    static let presets: [LabScenario] = [.navigateAway, .signOut, .burst]
}

extension LabRequest {
    static func reply(owner: String) -> LabRequest {
        LabRequest(owner: owner, intent: "Generate reply", resource: "reply:42", lane: LabScenario.llm,
                   ownedLifetime: .scope(.session), durationTicks: 12, costPerTick: 40)
    }

    static func summary(owner: String, doc: Int) -> LabRequest {
        LabRequest(owner: owner, intent: "Summarize doc \(doc)", resource: "summary:\(doc)", lane: LabScenario.llm,
                   ownedLifetime: .owner, durationTicks: 8, costPerTick: 25)
    }
}
