# OperationOwnership

**The Task is not the unit of work. Ownership is.**

A Swift concurrency runtime where every piece of work declares its **intent, owner, resource and lifetime** before it picks a mechanism. One actor (`OperationCenter`) then decides whether that work starts, joins work already in flight, waits, or is refused, and it cancels work only when nobody owns it any more.

The flagship case is an AI feature. A streaming generation belongs to the user's *session*, not to the screen that started it. Leaving the screen doesn't orphan the stream or burn tokens twice. Coming back joins the stream that's already running. Signing out ends it. A draft upload marked must-finish still lands.

Demo app: **[operation-ownership-demo-app](https://github.com/rajatslakhina/operation-ownership-demo-app)**. It is a separate iOS project that consumes this package as a remote Swift package (up to next major from 1.0.0) and shows the three ownership models side by side.

---

## Why this matters

Most cancellation bugs in SwiftUI apps come from one shortcut: tying work to whichever lifetime is closest at hand. That is usually a view's `.task` or an unstructured `Task {}`. Both answer the wrong question.

| | `.task`-bound | `Task { }` fire-and-forget | **Owned (this library)** |
|---|---|---|---|
| User leaves a screen mid-stream | Stream cancelled; tokens already spent are sunk | Stream finishes for nobody | Session keeps it; the returning screen joins it |
| Three rows ask for the same summary | Three executions | Three executions | **One** execution, three claims |
| User signs out mid-stream | Cancelled (correct), but the draft upload dies too | Stream keeps running after sign-out | Stream ends; must-finish upload lands |
| Who can cancel it? | The view | Nobody | Whoever owns it, and only once *all* owners are gone |

At team scale this is a platform decision, not a code-review nit. Without a shared model, each feature team invents its own cancellation rules. The AI features then pay twice: for the tokens, and for the support tickets when a reply vanishes or keeps generating after sign-out.

### The numbers

These figures come from the virtual-time `OwnershipLab`. It drives the **real ledger** through three scripted journeys, once per strategy. Every value in these tables is asserted in `LabTests`, so a regression in anchoring, coalescing, draining or waste accounting changes at least one of them.

**Leave and return mid-generation**: 12 ticks at 40 tokens/tick. The user leaves at tick 4 and reopens the screen at tick 6.

| Metric | `.task` | `Task {}` | Owned |
|---|---:|---:|---:|
| Executions | 2 | 2 | **1** |
| Tokens spent | 640 | 960 | **480** |
| Tokens wasted | 160 | 480 | **0** |
| Orphaned completions | 0 | 1 | 0 |
| Result reaches the returning screen at tick | 17 | 17 | **11** |

**Sign out mid-generation**: a draft upload (must-finish) starts at tick 3. Sign-out happens at tick 5.

| Metric | `.task` | `Task {}` | Owned |
|---|---:|---:|---:|
| Cancelled | 2 (stream **and** upload) | 0 | 1 (stream only) |
| Orphaned completions | 0 | 2 (ran past sign-out) | 0 |
| Durable completions (upload landed, owned) | 0 | 0 | **1** |
| Tokens wasted | 200 | 480 | 200 |

Owned work is not immortal: sign-out wastes the same 200 tokens as `.task`, because ending the session *should* end the stream.

**Three rows, one summary**: one model slot, 8 ticks at 25 tokens. Rows 1–3 ask for doc 7 and row 3 also asks for doc 9.

| Metric | `.task` | `Task {}` | Owned |
|---|---:|---:|---:|
| Executions | 4 | 4 | **2** |
| Tokens spent | 800 | 800 | **400** |
| Last result at tick | 31 | 31 | **15** |

---

## The model

```
app ─── session ─── flow "chat" ─┬─ view "reply-screen#1"   (closed at tick 4)
                                 └─ view "reply-screen#2"   (opened at tick 6)

op1 "Generate reply"  running · claims:
  ○ detached  reply-screen#1 (closed) → kept by session [scope(session)]
  ◉ awaiting  reply-screen#2          → kept by session [scope(session)]
```

- **Owners** form a tree: `view → flow → session → account → app`. A child must be strictly narrower than its parent. Closing an owner closes its whole subtree.
- A **claim** is one requester's interest in one operation. It records two owners:
  - the **requester**: who is waiting for the value;
  - the **anchor**: who keeps the work alive. The anchor comes from the declared `Lifetime`.
- **`Lifetime`**:
  - `.owner` is structured: the claim dies with its view or its awaiting caller, which is `.task` semantics.
  - `.scope(.session)` means the caller may leave and the nearest enclosing session keeps the work alive.
  - `.mustFinish` is never cancelled by ownership. Use it for side effects that must land. The **budget** can still stop it: work that outruns its reservation and can't be covered is cancelled, whatever its lifetime.
- An **operation** runs while it has at least one live claim. It is cancelled when it has none, and never because one of several requesters left.
- **`Sharing`** decides what happens when a request names a resource that already has work in flight:
  - `.coalesce` joins it;
  - `.replace` makes the latest request win (search-as-you-type); the new work waits for the superseded task to drain;
  - `.serialize` queues behind it (per-resource FIFO);
  - `.rejectIfBusy` refuses;
  - `.independent` ignores the resource.

  Resource keys are a namespace across lanes. A `.coalesce` joiner joins the in-flight operation on whatever lane that operation runs, whatever lane the joiner declared.
- **Lanes** (`llm`, `network`, `io`) have their own `maxConcurrent`/`maxQueued` limits, so a burst of thumbnails can't starve a generation.
- **Budget**: admission reserves the estimate; streaming consumes it; ending the operation releases whatever was left unspent. Joiners reserve nothing, which is where coalescing saves money.

```swift
let center = OperationCenter(configuration: .init(
    lanes: [Lane("llm"): .init(maxConcurrent: 2, maxQueued: 8)],
    budgetCapacity: 200_000))

let session = try await center.openOwner(.session, label: "session", parent: center.root)
let screen  = try await center.openOwner(.view, label: "reply", parent: session)

let reply: String = try await center.perform(OperationRequest(
    intent: "Generate reply",
    owner: screen,
    resource: ResourceKey("reply:\(messageID)"),
    lane: Lane("llm"),
    lifetime: .scope(.session),   // the session owns the stream, not the screen
    sharing: .coalesce,           // a returning screen joins it
    priority: .userInitiated,
    costEstimate: 1_200)) { context in
        var text = ""
        for try await chunk in model.stream(prompt) {
            try await context.consume(chunk.tokenCount) // throws once nobody owns the work
            text += chunk.text
        }
        return text
    }

// .onDisappear  → try await center.closeOwner(screen)   // the stream keeps going
// sign-out      → try await center.closeOwner(account)  // the stream stops; must-finish work lands
```

---

## Architecture

```
Sources/OperationOwnership/
  Model.swift            ScopeKind, Lifetime, Sharing, Lane, LaneLimits, OperationRequest, effects, errors
  OwnershipLedger.swift  Functional core: a synchronous, deterministic state machine → [LedgerEffect]
  OperationCenter.swift  Imperative shell (actor): effects → Tasks, cancellations, continuation resumes
  Budget.swift           TokenBudget (reserve → consume → release), Saturating, RingBuffer
  Records.swift          Totals, history, events, OwnershipSnapshot (value-typed, for inspectors)
  LedgerAudit.swift      Independent invariant checkers, usable in debug builds
  OwnershipLab.swift     Virtual-time harness + the three preset journeys
Sources/OperationOwnershipUI/
  OwnershipLabView.swift SwiftUI comparison card, scrubbable ownership-tree timeline, event log
```

**Functional core, imperative shell.** `OwnershipLedger` never spawns a task, never sleeps and never reads a clock. It takes inputs (`openOwner`, `closeOwner`, `submit`, `detach`, `consume`, `finish`) and returns ordered `LedgerEffect`s (`start`, `cancel`, `resolve`). The `OperationCenter` actor executes those effects. The lab executes the same effects in virtual time. Every ordering guarantee is therefore tested synchronously, and the async tests only cover the shell's wiring.

### Guarantees

Each is pinned by tests. Where a guarantee is checked by an auditor (`LedgerAudit.effects`, `.batch`, `.snapshot`, `.budget`, `OwnershipLedger.auditResourceQueues()`), a test feeds that auditor a deliberately broken input and asserts the exact violations it reports, so the checker is shown to fail.

1. **Ownership is the only cancellation authority.** An operation is cancelled exactly when its last live claim goes away. `testCoalescedWorkSurvivesOneRequesterLeaving`. `testSurvivalPropertyFailsForTheTaskBoundModel` shows the same survival check failing for the `.task`-bound policy.
2. **Exactly one resolution per claim.** A seeded random walk runs 200 seeds × 400 steps, randomly sampling lifetimes, sharing modes, priorities and two deliberately unequal lanes (1 slot vs 3) that share the same two resources. It runs every auditor after every ledger call, and finally asserts that every accepted claim was resolved once and only once, and that nothing leaked: no claims, no operations, no reservation.
3. **Limits bound real work.** A cancelled operation keeps its lane slot *and* its place at the head of its resource queue until its task actually stops. So `maxConcurrent` bounds running tasks, `.serialize` stays exclusive while a writer winds down, and no single ledger call ever starts work it also cancels. Queue promotions are deferred until every release in a call has been applied, so a waiter can't be promoted, started and then cancelled by the next release in the same call, even when one resource is used from two lanes. `testLaneSlotIsHeldWhileDraining`, `testSerializedResourceStaysExclusiveWhileTheHeadDrains`, `testReplaceOverASerializeQueueStartsNothingItCancels`, `testCrossLaneCloseStartsNothingItCancels`, `testCrossLaneReplaceKeepsTheResourceExclusive`.
4. **Bounded memory.** Owners (`maxOwners`), queued work (`maxQueued` per lane, covering waiting-on-resource too), claims per operation (`maxClaimsPerOperation`, which also bounds the detached claims a long session-scoped stream collects), history and events (ring buffers, capped at 65,536 however they are configured) are all bounded.
5. **The budget never goes negative.** `reserved + spent ≤ capacity` holds after every call in the random walk and in every lab frame.
6. **No trapping arithmetic on the public surface.** Ledger counters and budget maths go through `Saturating`; ids wrap (`&+`) instead of trapping; ceilings derive from `Int.max`. The few plain `+= 1` left (lab metrics, a loop guard) are bounded by scenario length. The only `Int(Double)` conversion (the UI slider) is guarded for NaN/∞ and clamped.

### Actor reentrancy

No `OperationCenter` method mutates state across an `await`. Each entry point does all of its ledger work and applies all effects in one synchronous actor turn. The only suspension is a caller waiting on its own continuation.

Task completion re-enters through `taskFinished`, which is again a single turn. Stale completions are ignored, such as a task finishing after it was cancelled: the ledger only accepts `finish` for `running` or `draining` operations.

A resolution that arrives before its waiter is installed is buffered (`early`) rather than dropped. Today's isolation inheritance means that window doesn't exist, but correctness shouldn't depend on it. This defensive path is not reachable today, so no test exercises it.

---

## Design decisions and trade-offs

| Decision | Chosen | Rejected, and why |
|---|---|---|
| Where cancellation authority lives | A ledger of **claims** with requester ≠ anchor | Ref-counting `Task` handles: it can't tell "the caller left" apart from "the owner closed", so session-scoped work either dies with the screen or never dies |
| How must-finish work survives | The center owns the task, unstructured; ownership never cancels a pinned claim | A cancellation-shield API inside the work: it keeps the side effect alive, but the work becomes invisible to the inspector, to the budget and to sign-out accounting. It is also not available on the Swift 6.0 floor this package supports |
| Cancelled work, lane slots and resources | Slot **and** resource held until the task **drains** | Freeing them at cancel time: a slow-to-cancel stream plus its replacement would exceed `maxConcurrent`, and two "serialized" writers would overlap. The limits would bound bookkeeping instead of the GPU, the socket or the file. The cost: `.replace` waits one drain before the latest query starts |
| When budget is reserved | At **admission** (held while queued) | At start: the ledger would admit work it may never be able to pay for, and only discover it when the work reaches the front of the queue. The cost of reserving early is that a long queue holds budget; `maxQueued` bounds that cost |
| `.replace` when the lane is full | Refused whole (`.overloaded`); the victims are untouched | Supersede first, then admit: if admission then fails, you've cancelled work you couldn't replace. The admission check is deliberately conservative: it doesn't credit the slots the victims would free |
| `.replace` against must-finish work | Refused (`.resourcePinned`) | Superseding it would break the must-finish promise |
| Who gets a coalesced result | Every awaiting claimant gets the same value; a type mismatch throws `.typeMismatch` | Per-claim generics: resource keys are a namespace, and two types on one key is a programming error worth surfacing |
| "Orphaned" vs "retained" | *Retained*: nobody awaited, but a live scope below the app root still owned the work. *Orphaned*: not even that. The center does not cache values; for retained work the side effect (e.g. writing into a session store) is the hand-off | Counting only cancellations as waste would make `Task {}` look free |
| Failure vs waste | Failures are counted under `failed`, not `wastedCost` | Blending them hides which problem you have: a product failure or an ownership leak |
| Priority | Highest priority first, then FIFO; a higher-priority **joiner** lifts a queued operation. The started `Task` gets the matching `TaskPriority` | Pure FIFO: a user-initiated tap that coalesces onto a background prefetch would wait behind it |

### Limits (deliberately out of scope)

- **No clock, so no deadlines.** Work that must finish should carry its own timeout. The ledger stays clock-free so it stays deterministic.
- **The center is in-process.** Cross-process ownership (an extension plus the app) would need a fenced lease, for example a file lock with a fencing token.
- **Cost is whatever unit you report.** The lab uses tokens. The ledger doesn't price anything. Reporting a negative amount is a programming error: `consume` throws, and the work stops.
- **The view model recomputes on re-init.** `OwnershipLabView` builds its model in `State(initialValue:)`, which is cheap for the presets and harmless at the app root. Hoist the model if you embed the view deep in a frequently re-rendered hierarchy.
- **The lab is a model, not a benchmark.** Its numbers show what each ownership policy does to the same script. They are not measurements of a real model or network.

---

## How to run it

Requires Swift 6.0+ (Xcode 16+ on macOS). The core target has no Foundation import and builds on Linux.

```bash
git clone https://github.com/rajatslakhina/operation-ownership-kit.git
cd operation-ownership-kit
swift build -Xswiftc -warnings-as-errors
swift test
```

To *see* the lab, run the companion demo app (link at the top), or call it from a test or a playground:

```swift
for run in OwnershipLab.compare(.navigateAway) {
    print(run.strategy.title, run.metrics.costSpent, run.metrics.costWasted)
}
```

## Verification

Here is what has actually been run:

- **Local (Swift 6.0.3, Linux):** after `rm -rf .build`, `swift build -Xswiftc -warnings-as-errors` builds with 0 warnings. `swift test` runs **62 tests with 0 failures**. Eleven hand-made ledger mutants were run during development, and the suite at the time killed each one. Examples: releasing claims when the requester closes, freeing slots at cancel time, pumping queues mid-call, and dropping the priority comparison.
- **GitHub Actions** ([Actions tab](https://github.com/rajatslakhina/operation-ownership-kit/actions)): green on the `v1.0.0` commit.
  - **Linux:** `swift:6.0` container, clean `swift build -Xswiftc -warnings-as-errors`, then `swift test`.
  - **macOS 15:** Xcode 16.4, `swift test`, which also compiles the SwiftUI target. Then `xcodebuild build -scheme OperationOwnership-Package -destination 'generic/platform=iOS Simulator'`. This is a compile-only check; no device or simulator runtime is needed.
- **Simulator:** this package has no app target. The companion demo app was built in Xcode 26.3 against the `1.0.0` tag resolved from GitHub, then launched and used on the iPhone 17 Pro Simulator (iOS 26.3). Its README has the screenshots.

## Install

```swift
.package(url: "https://github.com/rajatslakhina/operation-ownership-kit.git", from: "1.0.0")
```

Products: `OperationOwnership` (core, Foundation-free, builds on Linux) and `OperationOwnershipUI` (SwiftUI, iOS 17 / macOS 14).

## License

MIT
