import SwiftUI

/// One compact line of Claude limits: `5h 1%  Week 32%  Fable 35%`, each with a
/// hairline bar. Hovering a limit swaps its text for the reset time.
struct UsageView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = UsageMonitor.shared
    @ObservedObject private var codex = CodexManager.shared
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0

    /// Codex sessions show Codex's limits; every other session shows Claude's, as before.
    private var isCodex: Bool { store.selectedProvider == .codex }
    private var limits: [UsageMonitor.Limit] { isCodex ? codex.limits : monitor.limits }

    /// On the project rail the limits are one small set of nested rings, and lines of text
    /// beside it only while the rail is open; under the session list they are bars.
    var onRail = false
    var railOpen = false

    var body: some View {
        Group {
            if onRail { rings } else { bars }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .onChange(of: usageInterval) { _, seconds in monitor.schedule(every: seconds) }
        .task(id: isCodex) {
            guard isCodex else { return }
            while !Task.isCancelled {
                await codex.refreshUsage()
                try? await Task.sleep(for: .seconds(max(usageInterval, 30)))
            }
        }
    }

    private var summary: String {
        let name = isCodex ? "Codex" : "Claude"
        guard !limits.isEmpty else { return (isCodex ? codex.usageError : monitor.error) ?? "\(name) limits are loading" }
        return name + " limits\n" + limits.map { "\($0.label) \($0.percent)% used" + ($0.resetShort.map { ", resets in \($0)" } ?? "") }.joined(separator: "\n")
    }

    /// On the rail: each limit as its percentage over a hairline bar, "5h" and "Week" first, so
    /// how much is left reads at a glance without opening anything. Open, the reset times
    /// follow beside it. A click checks again.
    private var rings: some View {
        let shown = Array(limits.prefix(2))
        return HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 5) {
                if shown.isEmpty {
                    // Nothing read yet, or it failed: say so instead of an empty shape.
                    Image(systemName: (isCodex ? codex.usageError : monitor.error) == nil ? "gauge.with.dots.needle.33percent" : "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(height: 22)
                }
                ForEach(shown) { limit in
                    VStack(spacing: 1.5) {
                        Text(limit.label)
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        Text("\(limit.percent)%")
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(limit.percent >= 90 ? Palette.error : limit.percent >= 70 ? Palette.needs : .primary.opacity(0.85))
                            .minimumScaleFactor(0.7)
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.1))
                            Capsule().fill(limit.tint).frame(width: max(2, 26 * CGFloat(min(limit.percent, 100)) / 100))
                        }
                        .frame(width: 26, height: 2.5)
                    }
                }
            }
            .lineLimit(1)
            .frame(width: 30)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { if isCodex { Task { await codex.refreshUsage() } } else { monitor.refresh() } }
            .help(railOpen ? "" : (limits.isEmpty ? (isCodex ? codex.usageError : monitor.detail) ?? summary : summary))
            if railOpen {
                VStack(alignment: .leading, spacing: 3) {
                    if limits.isEmpty {
                        Text((isCodex ? codex.usageError : monitor.error) ?? "Loading limits…").foregroundStyle(.secondary)
                    }
                    ForEach(limits.prefix(3)) { limit in
                        HStack(spacing: 5) {
                            Text(limit.label).foregroundStyle(.secondary)
                            Text("\(limit.percent)%")
                                .fontWeight(.medium)
                                .foregroundStyle(limit.percent >= 90 ? Palette.error : limit.percent >= 70 ? Palette.needs : .primary.opacity(0.85))
                            if let reset = limit.resetShort { Text("· \(reset)").foregroundStyle(.tertiary) }
                        }
                    }
                }
                .font(.system(size: 10).monospacedDigit())
                .lineLimit(1)
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
    }

    private var bars: some View {
        // The agent's mark, then one line a limit: what it is, how much is used, when it starts over.
        HStack(alignment: .top, spacing: 9) {
            ProviderLogo(provider: isCodex ? .codex : .claude, size: 12)
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 13)
                .help(isCodex ? codex.plan.map { "Codex \($0.replacingOccurrences(of: "_", with: " ").capitalized) limits" } ?? "Codex limits" : "Claude limits")
            VStack(alignment: .leading, spacing: 4) {
                if limits.isEmpty {
                    Button {
                        if isCodex { Task { await codex.refreshUsage() } } else { monitor.refresh() }
                    } label: {
                        Text(isCodex ? codex.usageError ?? "Loading limits…" : monitor.error ?? "Loading limits…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(height: 13)
                    }
                    .buttonStyle(.plain)
                    .help(isCodex ? codex.usageError ?? "" : monitor.detail ?? "")
                }
                ForEach(limits) { limit in
                    HStack(spacing: 7) {
                        Text(limit.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.08))
                                Capsule().fill(limit.tint)
                                    .frame(width: max(3, geo.size.width * CGFloat(min(limit.percent, 100)) / 100))
                            }
                        }
                        .frame(height: 3)
                        Text("\(limit.percent)%")
                            .fontWeight(.medium)
                            .foregroundStyle(limit.percent >= 90 ? Palette.error : limit.percent >= 70 ? Palette.needs : .primary.opacity(0.85))
                            .frame(width: 28, alignment: .trailing)
                        Text(limit.resetShort ?? "")
                            .foregroundStyle(.tertiary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .lineLimit(1)
                    .frame(height: 13)
                    .help("\(limit.percent)% used, \(max(0, 100 - limit.percent))% left. \(limit.resetText)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
