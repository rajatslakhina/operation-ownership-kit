#if canImport(SwiftUI)
import SwiftUI
import Observation
import OperationOwnership

/// View model for the lab. Every number it shows comes from `OwnershipLab`,
/// which drives the real `OwnershipLedger`; nothing here is mocked.
@MainActor
@Observable
public final class OwnershipLabModel {
    public let scenarios: [LabScenario]
    public private(set) var runs: [LabRun] = []
    public var selectedStrategy: LabStrategy = .owned
    public var tick: Int = 0

    public var scenarioID: String {
        didSet { recompute() }
    }

    public init(scenarios: [LabScenario], initialScenarioID: String? = nil) {
        // An empty list would leave nothing to select; fall back to the presets.
        let available = scenarios.isEmpty ? LabScenario.presets : scenarios
        self.scenarios = available
        self.scenarioID = initialScenarioID.flatMap { id in available.first { $0.id == id }?.id }
            ?? available.first?.id ?? ""
        recompute()
    }

    public var scenario: LabScenario? { scenarios.first { $0.id == scenarioID } }

    public var selectedRun: LabRun? { runs.first { $0.strategy == selectedStrategy } }

    public var frame: LabFrame? {
        guard let frames = selectedRun?.frames, !frames.isEmpty else { return nil }
        let index = min(max(0, tick), frames.count - 1)
        return frames.indices.contains(index) ? frames[index] : nil
    }

    private func recompute() {
        guard let scenario else {
            runs = []
            tick = 0
            return
        }
        runs = OwnershipLab.compare(scenario)
        tick = scenario.endTick / 2
    }
}

public struct OwnershipLabView: View {
    @State private var model: OwnershipLabModel

    public init(scenarios: [LabScenario] = LabScenario.presets, initialScenarioID: String? = nil) {
        _model = State(initialValue: OwnershipLabModel(scenarios: scenarios, initialScenarioID: initialScenarioID))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scenarioPicker
                    if model.runs.isEmpty {
                        ContentUnavailableView("No scenario", systemImage: "square.dashed",
                                               description: Text("Provide at least one LabScenario."))
                    } else {
                        ComparisonCard(runs: model.runs)
                        timeline
                        EventLog(events: model.selectedRun?.events ?? [])
                    }
                }
                .padding()
            }
            .navigationTitle("Operation Ownership")
        }
    }

    private var scenarioPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Scenario", selection: $model.scenarioID) {
                ForEach(model.scenarios) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("scenarioPicker")
            if let scenario = model.scenario {
                Text(scenario.summary).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ownership tree over time").font(.headline)
            Picker("Strategy", selection: $model.selectedStrategy) {
                ForEach(LabStrategy.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            if let scenario = model.scenario, scenario.endTick > 0 {
                HStack {
                    Text(verbatim: "Tick \(model.tick)").font(.subheadline.monospacedDigit()).frame(width: 64, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(model.tick) },
                        set: { newValue in
                            // Int(Double) traps on NaN/∞; clamp a finite value into range first.
                            guard newValue.isFinite else { return }
                            model.tick = Int(max(0, min(Double(scenario.endTick), newValue.rounded())))
                        }
                    ), in: 0...Double(scenario.endTick), step: 1)
                    .accessibilityIdentifier("tickSlider")
                }
            }
            if let frame = model.frame {
                TreeView(snapshot: frame.snapshot)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension LabStrategy {
    var shortTitle: String {
        switch self {
        case .taskBound: return ".task"
        case .fireAndForget: return "Task {}"
        case .owned: return "Owned"
        }
    }
}

struct ComparisonCard: View {
    let runs: [LabRun]

    private struct Row: Identifiable {
        let id: String
        let value: (LabMetrics) -> String
        let lowerIsBetter: Bool?
        let numeric: (LabMetrics) -> Int
    }

    private let rows: [Row] = [
        Row(id: "Executions", value: { "\($0.executionsStarted)" }, lowerIsBetter: true, numeric: { $0.executionsStarted }),
        Row(id: "Coalesced joins", value: { "\($0.coalescedJoins)" }, lowerIsBetter: nil, numeric: { $0.coalescedJoins }),
        Row(id: "Tokens spent", value: { "\($0.costSpent)" }, lowerIsBetter: true, numeric: { $0.costSpent }),
        Row(id: "Tokens wasted", value: { "\($0.costWasted)" }, lowerIsBetter: true, numeric: { $0.costWasted }),
        Row(id: "Orphaned completions", value: { "\($0.orphanedCompletions)" }, lowerIsBetter: true, numeric: { $0.orphanedCompletions }),
        Row(id: "Durable completions", value: { "\($0.durableCompletions)" }, lowerIsBetter: nil, numeric: { $0.durableCompletions }),
        Row(id: "Results delivered", value: { "\($0.resultsDelivered)" }, lowerIsBetter: nil, numeric: { $0.resultsDelivered }),
        Row(id: "Last result (tick)", value: { $0.lastResultTick.map(String.init) ?? "—" }, lowerIsBetter: nil, numeric: { $0.lastResultTick ?? 0 }),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Same journey, three ownership models").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(runs) { Text($0.strategy.shortTitle).font(.caption.bold()) }
                }
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Text(row.id).font(.caption).gridColumnAlignment(.leading)
                        ForEach(runs) { run in
                            Text(row.value(run.metrics))
                                .font(.caption.monospacedDigit())
                                .fontWeight(isBest(row, run) ? .bold : .regular)
                                .foregroundStyle(isBest(row, run) ? Color.green : Color.primary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("comparisonCard")
    }

    private func isBest(_ row: Row, _ run: LabRun) -> Bool {
        guard row.lowerIsBetter == true, runs.count > 1 else { return false }
        let values = runs.map { row.numeric($0.metrics) }
        guard let best = values.min(), let worst = values.max(), best != worst else { return false }
        return row.numeric(run.metrics) == best
    }
}

struct TreeView: View {
    let snapshot: OwnershipSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.owners) { owner in
                HStack(spacing: 6) {
                    Text(owner.kind.description)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color(for: owner.kind).opacity(0.2), in: Capsule())
                    Text(owner.label).font(.caption)
                    if owner.anchoredClaims > 0 {
                        Text(verbatim: "keeps \(owner.anchoredClaims) alive").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, CGFloat(min(owner.depth, 8)) * 14)
            }
            Divider()
            if snapshot.operations.isEmpty {
                Text("No live operations").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.operations) { op in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: "\(op.id) · \(op.intent)").font(.caption.bold())
                        Spacer()
                        Text(op.state.rawValue).font(.caption2).foregroundStyle(stateColor(op.state))
                    }
                    Text(verbatim: "\(op.lane) · \(op.consumed) tokens spent · \(op.reservedRemaining) reserved")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    ForEach(op.claims) { claim in
                        Text(verbatim: Self.describe(claim))
                            .font(.caption2)
                    }
                }
            }
        }
    }

    static func describe(_ claim: OwnershipSnapshot.ClaimRow) -> String {
        let marker = claim.awaiting ? "◉ awaiting" : "○ detached"
        return "\(marker) · \(claim.requester) → kept by \(claim.anchor) [\(claim.lifetime.description)]"
    }

    private func color(for kind: ScopeKind) -> Color {
        switch kind {
        case .app: return .gray
        case .account: return .purple
        case .session: return .blue
        case .flow: return .teal
        case .view: return .orange
        }
    }

    private func stateColor(_ state: OwnershipLedger.OperationState) -> Color {
        switch state {
        case .running: return .green
        case .draining: return .red
        case .queued, .waitingOnResource: return .orange
        }
    }
}

struct EventLog: View {
    let events: [LedgerEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Ledger events, whole run (\(events.count))").font(.headline)
            if events.isEmpty {
                Text("No events").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(events.suffix(40)) { event in
                Text(verbatim: "\(event.sequence). \(event.message)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(event.kind == .cancelled || event.kind == .rejected ? Color.red : Color.primary)
            }
        }
    }
}
#endif
