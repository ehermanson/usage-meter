import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if store.providers.isEmpty && store.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(store.providers) { provider in
                    ProviderRow(provider: provider)
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { Task { await store.refresh() } }
    }

    private var header: some View {
        HStack {
            Text("Usage Limits")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(updatedText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private var updatedText: String {
        guard let d = store.lastUpdated else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return "Updated \(f.string(from: d))"
    }
}

private struct ProviderRow: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(provider.name)
                    .font(.system(size: 12, weight: .semibold))
                if let plan = provider.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }

            ForEach(provider.windows) { window in
                WindowBar(window: window)
            }

            // A note shown alongside windows means we're displaying a stale
            // value; with no windows it's a hard error.
            if let note = provider.error {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(provider.windows.isEmpty ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WindowBar: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(window.usedPercent))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(3, geo.size.width * window.clampedFraction))
                }
            }
            .frame(height: 6)
            if let reset = window.resetAt {
                Text(Format.relativeReset(reset))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var barColor: Color {
        switch window.usedPercent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}
