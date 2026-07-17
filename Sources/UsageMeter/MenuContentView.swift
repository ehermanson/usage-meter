import SwiftUI

struct MenuContentView: View {
    @Bindable var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var updates = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.providers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if store.visibleProviders.isEmpty {
                noProvidersDetected
            } else {
                ForEach(store.visibleProviders) { provider in
                    if provider.id != store.visibleProviders.first?.id {
                        Divider().opacity(0.5)
                    }
                    let style = store.style(for: provider.name)
                    ProviderRow(
                        provider: provider,
                        accent: style.accent,
                        logoResource: style.logoResource,
                        showRemaining: store.showRemaining)
                }
            }

            Divider()

            // The picker only matters when there's a choice of provider to pin;
            // with a single source it always resolves to that one, so hide it.
            if store.selectableProviders.count > 1 {
                menuBarPicker
            }

            if store.compactMenuBarApplies {
                Toggle("Compact (5hr only)", isOn: $store.compactMenuBar)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            Toggle("Show % remaining", isOn: $store.showRemaining)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            // Only offered once Claude Code was detected — for setups where the
            // sign-in lives in a non-default CLAUDE_CONFIG_DIR the auto-detect
            // heuristic can't see (e.g. one set only inside a shell alias).
            if store.visibleProviders.contains(where: { $0.name == "Claude" }) {
                claudeConfigPicker
            }

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: launchAtLogin) { _, newValue in
                    applyLaunchAtLogin(newValue)
                }

            if let update = updates.availableUpdate {
                Divider()
                updateRow(version: update.version)
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
            Task { await updates.check() }
        }
    }

    // Shown when none of the supported tools are installed on this machine — the
    // app has nothing to track. A calm note rather than an error or install nudge.
    private var noProvidersDetected: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No usage to show")
                .font(.system(size: 12, weight: .semibold))
            Text(
                "Usage Meter tracks your limits once Claude Code, Codex, or Gemini is set up on this Mac."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
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

    /// "Auto" resolves the Claude config dir the way the user's terminal would;
    /// choosing a folder pins CLAUDE_CONFIG_DIR for the usage fetch instead.
    private var claudeConfigPicker: some View {
        Menu {
            Button {
                store.claudeConfigDir = nil
            } label: {
                pickerRow("Auto-detect", checked: store.claudeConfigDir == nil)
            }
            if store.claudeConfigDir != nil {
                Button {
                    // Current selection — shown for context, nothing to do.
                } label: {
                    pickerRow(store.claudeConfigDirLabel, checked: true)
                }
                .disabled(true)
            }
            Divider()
            Button("Choose Folder…") { chooseClaudeConfigDir() }
        } label: {
            Label("Claude config: \(store.claudeConfigDirLabel)", systemImage: "folder")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(
            "Where Claude Code keeps its sign-in (CLAUDE_CONFIG_DIR). "
                + "Auto works for most setups.")
    }

    // Shown only when GitHub has a release newer than this build. Clicking opens
    // the .dmg download — the lightweight update path (no in-place swap).
    private func updateRow(version: String) -> some View {
        Button {
            updates.openDownload()
        } label: {
            Label("Update to v\(version)", systemImage: "arrow.down.circle")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Download the latest Usage Meter from GitHub")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            updatedLabel

            if store.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Button("Refresh", systemImage: "arrow.clockwise", action: refreshNow)
                    .labelStyle(.iconOnly)
                    .help("Refresh now")
            }

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

    private func chooseClaudeConfigDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Config dirs are dotfolders (~/.claude), invisible without this.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message =
            "Choose the folder Claude Code keeps its sign-in state in (usually ~/.claude)."
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            store.claudeConfigDir = url.path
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if !LoginItem.setEnabled(enabled) {
            launchAtLogin = LoginItem.isEnabled  // revert on failure
        }
    }
}
