import SwiftUI

struct MenuContentView: View {
    @Bindable var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var updates = UpdateChecker.shared
    @State private var installer = UpdateInstaller.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.providers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if store.visibleProviders.isEmpty {
                noProvidersDetected
            } else {
                // Each provider sits in its own soft card — grouping comes from
                // the surface, not dividers, which keeps sections scannable.
                ForEach(store.visibleProviders) { provider in
                    let style = store.style(for: provider.name)
                    ProviderRow(
                        provider: provider,
                        accent: style.accent,
                        logoResource: style.logoResource,
                        showRemaining: store.showRemaining
                    )
                    .cardSurface()
                }
            }

            settingsCard

            if let update = updates.availableUpdate {
                updateRow(update)
            }

            footer
        }
        .padding(12)
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

    /// All preferences grouped in one card, System Settings-style: every row is
    /// a plain label on the left and its control on the right, so mixed control
    /// types (menus, switches) still scan as one aligned column.
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Settings")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .kerning(0.6)

            // The picker only matters when there's a choice of provider to pin;
            // with a single source it always resolves to that one, so hide it.
            if store.selectableProviders.count > 1 {
                settingRow("Menu bar") { menuBarPicker }
            }

            if store.compactMenuBarApplies {
                settingRow("Compact (5hr only)") {
                    settingSwitch("Compact (5hr only)", isOn: $store.compactMenuBar)
                }
            }

            settingRow("Show % remaining") {
                settingSwitch("Show % remaining", isOn: $store.showRemaining)
            }

            settingRow("Launch at Login") {
                settingSwitch("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
            }

            // Last so the switches above stay a contiguous group. Only offered
            // once Claude Code was detected — for setups where the sign-in
            // lives in a non-default CLAUDE_CONFIG_DIR the auto-detect
            // heuristic can't see (e.g. one set only inside a shell alias).
            if store.visibleProviders.contains(where: { $0.name == "Claude" }) {
                settingRow("Claude config") { claudeConfigPicker }
            }
        }
        .cardSurface()
    }

    /// One settings row: label left, control right, on a consistent height so
    /// switch rows and menu rows line up.
    private func settingRow(
        _ label: String, @ViewBuilder control: () -> some View
    )
        -> some View
    {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 16)
    }

    /// A mini switch whose text label is hidden visually but kept for VoiceOver
    /// (the row's Text is a separate element, so the control needs its own).
    private func settingSwitch(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
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
            Text(store.pinnedDisplayLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
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
            // Bounded + middle-truncated so an arbitrarily long config path
            // can't push the control out of the fixed-width card; the full
            // path lives in the tooltip.
            Text(store.claudeConfigDirLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(
            store.claudeConfigDir.map { "CLAUDE_CONFIG_DIR: \($0)" }
                ?? "Where Claude Code keeps its sign-in (CLAUDE_CONFIG_DIR). "
                + "Auto works for most setups.")
    }

    // Shown only when GitHub has a release newer than this build. One click
    // runs the whole seamless flow inline — download progress, install,
    // relaunch — via UpdateInstaller. When an in-place swap isn't possible
    // (dev build, unwritable install, no zip asset) or it fails, the row
    // degrades to the browser download.
    @ViewBuilder
    private func updateRow(_ update: AvailableUpdate) -> some View {
        switch installer.phase {
        case .idle:
            updateButton(update)
        case .downloading(let fraction):
            HStack(alignment: .bottom, spacing: 8) {
                updateProgress("Downloading v\(update.version)…", fraction: fraction)
                Button {
                    installer.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Cancel the download")
            }
        case .installing:
            updateProgress("Installing…", fraction: nil)
        case .relaunching:
            updateProgress("Relaunching…", fraction: nil)
        case .installedNeedsRestart:
            // The swap already succeeded; only the auto-relaunch didn't start.
            VStack(alignment: .leading, spacing: 3) {
                Label("v\(update.version) installed", systemImage: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("Quit and reopen Usage Meter to finish.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Quit Now") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 12) {
                    Button {
                        Task { await installer.install(update) }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Button {
                        updates.openDownload()
                    } label: {
                        Label("Download v\(update.version)", systemImage: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Text("Couldn't auto-update: \(message)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func updateButton(_ update: AvailableUpdate) -> some View {
        let seamless = update.zipURL != nil && installer.canInstallInPlace
        return Button {
            if seamless {
                Task { await installer.install(update) }
            } else {
                updates.openDownload()
            }
        } label: {
            Label("Update to v\(update.version)", systemImage: "arrow.down.circle")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(
            seamless
                ? "Downloads, installs, and relaunches — nothing else to do"
                : "Download the latest Usage Meter from GitHub")
    }

    private func updateProgress(_ label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
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

            // The running version, so a just-installed update is verifiable at
            // a glance. Absent in dev builds (`swift run` has no Info.plist).
            if let version = Self.appVersion {
                Text("v\(version)")
                    .foregroundStyle(.tertiary)
            }

            Button("Quit", action: quit)
        }
        // Style the row once so the timestamp and both buttons stay consistent.
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    @ViewBuilder
    private var updatedLabel: some View {
        if let updated = store.lastUpdated {
            // Relative reads faster than a clock time and makes staleness
            // obvious. TimelineView keeps it ticking even when refreshes fail
            // (a failed pass leaves `lastUpdated` untouched, so nothing else
            // would re-render). Exact time lives in the tooltip.
            TimelineView(.everyMinute) { context in
                Text("Updated \(Format.updatedAgo(updated, now: context.date))")
            }
            .help("Last refreshed \(updated.formatted(date: .omitted, time: .standard))")
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

extension View {
    /// The panel's shared card treatment: a soft adaptive surface with a
    /// hairline stroke that crisps the edge (mostly visible in light mode).
    func cardSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return
            self
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }
}
