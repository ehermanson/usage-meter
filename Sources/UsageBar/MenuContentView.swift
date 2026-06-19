import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled

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

            Menu {
                Button { store.setPinned(nil) } label: {
                    pickerRow("Auto (peak)", checked: store.pinnedKey == nil)
                }
                if !store.selectableWindows.isEmpty { Divider() }
                ForEach(store.selectableWindows) { item in
                    Button { store.setPinned(item.key) } label: {
                        pickerRow(item.display, checked: store.pinnedKey == item.key)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pin")
                    Text("Menu bar: \(store.pinnedDisplayLabel)")
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11))

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: launchAtLogin) { newValue in
                    if !LoginItem.setEnabled(newValue) {
                        launchAtLogin = LoginItem.isEnabled // revert on failure
                    }
                }

            footer
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            Task { await store.refresh() }
        }
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

    @ViewBuilder
    private func pickerRow(_ text: String, checked: Bool) -> some View {
        if checked {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
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

            ForEach(provider.pools) { pool in
                if let title = pool.title {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                ForEach(pool.windows) { window in
                    WindowBar(window: window)
                }
            }

            // A note shown alongside windows means we're displaying a stale
            // value; with no windows it's a hard error.
            if let note = provider.error {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(provider.allWindows.isEmpty ? .red : .orange)
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
        case ..<60: return .green   // healthy
        case ..<90: return .yellow  // getting close
        default: return .red        // nearly exhausted
        }
    }
}
