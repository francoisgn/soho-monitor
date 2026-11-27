import SohoMonitorCore
import SwiftUI

/// The Claude card: one block per profile, in configuration order. A bar with the weekly limit (all models), then
/// one line per other limit (5-hour session, per-model weekly): small ring, percent, name, time to reset. Colours
/// come from `UsageLimit.reading(now:)`: pace, 90 % and the server's severity.
struct ClaudeCard: View {
    let model: ClaudeUsageModel
    let onDrag: (DesktopPanelController.DragPhase) -> Void
    let onResetPosition: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Claude").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if model.isRefreshing { ProgressView().controlSize(.mini) }
                }
                ForEach(Array(model.config.accounts.enumerated()), id: \.element) { index, account in
                    if index > 0 { Divider().opacity(0.5) }
                    ClaudeAccountBlock(
                        account: account, state: model.state(of: account),
                        refreshMinutes: model.config.refreshMinutes, now: context.date)
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(width: DiskCard.width, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.10), .clear, .white.opacity(0.04)], startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 28)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .contentShape(.rect(cornerRadius: 28))
        .onTapGesture(count: 2, perform: onResetPosition)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in onDrag(.changed) }
                .onEnded { _ in onDrag(.ended) }
        )
        .padding(12)
    }
}

/// One profile: label, weekly bar, percent and reset; one line per other limit below; then its state (waiting,
/// problem, stale).
private struct ClaudeAccountBlock: View {
    let account: ClaudeAccount
    let state: ClaudeAccountState
    let refreshMinutes: Int
    let now: Date

    /// Two columns: a third limit wraps to a second line instead of overflowing the card.
    private static let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .leading), GridItem(.flexible(), alignment: .leading),
    ]

    var body: some View {
        let stale = state.isStale(now: now, refreshMinutes: refreshMinutes)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .help(account.label)  // a long label is truncated: the full one on hover
                    if let plan = state.usage?.plan {
                        Text(plan.capitalized).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 74, alignment: .leading)
                if let weekly = state.usage?.weekly {
                    UsageBar(limit: weekly, now: now)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ResetFormat.percent(weekly.percent))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(ResetFormat.short(weekly.resetsAt, now: now))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .help(UsageText.help("Weekly limit, all models", weekly, now: now))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(UsageText.spoken("Weekly quota, all models", weekly, now: now))
                } else {
                    Spacer()
                }
            }
            if let usage = state.usage, usage.session != nil || !usage.models.isEmpty {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                    if let session = usage.session {
                        UsageLine(
                            title: "5h", help: "5-hour session", spoken: "5-hour quota", limit: session, now: now)
                    }
                    ForEach(usage.models, id: \.model) { scoped in
                        UsageLine(
                            title: scoped.model, help: "Weekly limit, \(scoped.model) only",
                            spoken: "\(scoped.model) weekly quota", limit: scoped.limit, now: now)
                    }
                }
                .padding(.leading, 84)
            }
            status(stale: stale)
        }
        .opacity(stale ? 0.55 : 1)
    }

    @ViewBuilder
    private func status(stale: Bool) -> some View {
        if let problem = state.problem {
            Text(problem.message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(state.usage == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if state.usage == nil {
            Text("Waiting for first update…").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        if stale, let usage = state.usage {
            Text("Figures from \(RelativeAge.string(from: usage.fetchedAt, now: now))")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Reading → Apple system colour: green on pace, yellow ahead of it, red at 90 % or the server's critical.
enum UsageColor {
    static func of(_ reading: UsageSeverity) -> Color {
        switch reading {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

/// A thin glass capsule filled to the limit's share.
private struct UsageBar: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(UsageColor.of(limit.reading(now: now)).gradient)
                .frame(width: max(limit.percent > 0 ? 4 : 0, proxy.size.width * limit.fraction))
        }
        .frame(height: 10)
        .background(.black.opacity(0.18))
        .overlay {
            LinearGradient(
                colors: [.white.opacity(0.35), .clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .clipShape(.capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .animation(.smooth, value: limit.percent)
    }
}

/// One limit on one line: a small ring, the percent, the limit's name and the time to its reset.
private struct UsageLine: View {
    let title: String
    let help: String
    let spoken: String
    let limit: UsageLimit
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(.black.opacity(0.18), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: limit.fraction)
                    .stroke(
                        UsageColor.of(limit.reading(now: now)).gradient,
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            .animation(.smooth, value: limit.percent)
            Text(ResetFormat.percent(limit.percent))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(ResetFormat.short(limit.resetsAt, now: now))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .help(UsageText.help(help, limit, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageText.spoken(spoken, limit, now: now))
    }
}
