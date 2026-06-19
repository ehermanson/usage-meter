import SwiftUI

struct MenuContentView: View {
    @Bindable var store: UsageStore
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
                    if provider.id != store.providers.first?.id {
                        Divider().opacity(0.5)
                    }
                    let style = store.style(for: provider.name)
                    ProviderRow(
                        provider: provider,
                        accent: style.accent,
                        logoResource: style.logoResource)
                }
            }

            Divider()

            menuBarPicker

            Toggle("Compact (5hr only)", isOn: $store.compactMenuBar)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: launchAtLogin) { _, newValue in
                    applyLaunchAtLogin(newValue)
                }

            footer
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            // Opening the menu only refetches when the data has gone stale; a
            // quick open right after a timer tick reuses what's already shown.
            if store.isStale {
                Task { await store.refresh() }
            }
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

    private var menuBarPicker: some View {
        Menu {
            Button {
                store.setPinned(nil)
            } label: {
                pickerRow(UsageStore.autoLabel, checked: store.pinnedProvider == nil)
            }
            if !store.selectableProviders.isEmpty { Divider() }
            ForEach(store.selectableProviders, id: \.self) { name in
                Button {
                    store.setPinned(name)
                } label: {
                    pickerRow(name, checked: store.pinnedProvider == name)
                }
            }
        } label: {
            Label("Menu bar: \(store.pinnedDisplayLabel)", systemImage: "pin")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            updatedLabel

            Button("Refresh", systemImage: "arrow.clockwise", action: refreshNow)
                .labelStyle(.iconOnly)
                .disabled(store.isLoading)
                .help("Refresh now")

            Spacer()

            Button("Quit", action: quit)
        }
        // Style the row once so the timestamp and both buttons stay consistent.
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private var updatedLabel: some View {
        if let updated = store.lastUpdated {
            Text("Updated \(updated, format: .dateTime.hour().minute().second())")
        } else {
            Text("—")
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

    // MARK: - Actions

    private func refreshNow() {
        Task { await store.refresh(force: true) }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if !LoginItem.setEnabled(enabled) {
            launchAtLogin = LoginItem.isEnabled  // revert on failure
        }
    }
}
