import SohoMonitorCore
import SwiftUI

/// The Claude card: one block per profile, in configuration order. A bar with the weekly limit (all models), then
/// donuts with the 5-hour session and each per-model weekly limit. Colours come from the server's severity.
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

/// One profile: label, weekly bar, percent and reset; donuts below; then its state (waiting, problem, stale).
private struct ClaudeAccountBlock: View {
    let account: ClaudeAccount
    let state: ClaudeAccountState
    let refreshMinutes: Int
    let now: Date

    var body: some View {
        let stale = state.isStale(now: now, refreshMinutes: refreshMinutes)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let plan = state.usage?.plan {
                        Text(plan.capitalized).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 74, alignment: .leading)
                if let weekly = state.usage?.weekly {
                    UsageBar(limit: weekly)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ResetFormat.percent(weekly.percent))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(UsageColor.of(weekly.severity))
                        Text(ResetFormat.relative(weekly.resetsAt, now: now))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                    .help("Weekly limit, all models")
                } else {
                    Spacer()
                }
            }
            if let usage = state.usage, usage.session != nil || !usage.models.isEmpty {
                HStack(spacing: 18) {
                    if let session = usage.session {
                        UsageDonut(title: "5h", limit: session, now: now).help("5-hour session")
                    }
                    ForEach(usage.models, id: \.model) { scoped in
                        UsageDonut(title: scoped.model, limit: scoped.limit, now: now)
                            .help("Weekly limit, \(scoped.model) only")
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

/// Server severity → Apple system colour.
enum UsageColor {
    static func of(_ severity: UsageSeverity) -> Color {
        switch severity {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// A thin glass capsule filled to the limit's share.
private struct UsageBar: View {
    let limit: UsageLimit

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(UsageColor.of(limit.severity).gradient)
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

/// A small ring with the percent in its centre, the title and the reset under it.
private struct UsageDonut: View {
    let title: String
    let limit: UsageLimit
    let now: Date

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.black.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: limit.fraction)
                    .stroke(
                        UsageColor.of(limit.severity).gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text(ResetFormat.percent(limit.percent))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 44, height: 44)
            .animation(.smooth, value: limit.percent)
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(ResetFormat.relative(limit.resetsAt, now: now))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 64)
    }
}
