import CompanionKit
import SwiftUI

private enum DashboardTab: String, CaseIterable, Identifiable {
    case limits = "Limits", tokens = "Tokens", cost = "Cost"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .limits: "gauge.with.dots.needle.67percent"
        case .tokens: "chart.bar"
        case .cost: "dollarsign.circle"
        }
    }
}

struct CompanionDashboard: View {
    @Bindable var store: CompanionStore
    @State private var tab: DashboardTab = .limits
    @State private var showConnection = false
    @State private var showSettings = false
    @State private var connectAfterSettings = false
    @AppStorage("showRemaining", store: UserDefaults(suiteName: CompanionConfiguration.appGroup))
    private var showRemaining = false
    @AppStorage("companion.activityRange") private var range = CompanionRange.week

    init(store: CompanionStore) {
        self.store = store
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--companion-demo") {
            if ProcessInfo.processInfo.arguments.contains("--companion-tab-tokens") {
                _tab = State(initialValue: .tokens)
            }
            if ProcessInfo.processInfo.arguments.contains("--companion-tab-cost") {
                _tab = State(initialValue: .cost)
            }
        }
        #endif
    }

    var body: some View {
        dashboardTabs
            .sensoryFeedback(.selection, trigger: tab)
            .onOpenURL { url in
                guard url.scheme == "usagemeter", url.host == "dashboard" else { return }
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                if let value = items?.first(where: { $0.name == "tab" })?.value,
                    let selected = DashboardTab.allCases.first(where: {
                        $0.rawValue.lowercased() == value
                    })
                {
                    tab = selected
                }
                if let value = items?.first(where: { $0.name == "range" })?.value,
                    let selected = CompanionRange(rawValue: value)
                {
                    range = selected
                }
            }
            .sheet(isPresented: $showConnection) { ConnectionSheet(store: store) }
            .sheet(
                isPresented: $showSettings,
                onDismiss: {
                    if connectAfterSettings { connectAfterSettings = false; showConnection = true }
                }
            ) {
                CompanionSettings(
                    store: store, showRemaining: $showRemaining,
                    requestConnection: {
                        connectAfterSettings = true; showSettings = false
                    })
            }
    }

    @ViewBuilder private var dashboardTabs: some View {
        if #available(iOS 18, *) {
            TabView(selection: $tab) {
                ForEach(DashboardTab.allCases) { item in
                    Tab(item.rawValue, systemImage: item.symbol, value: item) { page(item) }
                }
            }
        } else {
            TabView(selection: $tab) {
                ForEach(DashboardTab.allCases) { item in
                    page(item).tabItem { Label(item.rawValue, systemImage: item.symbol) }.tag(item)
                }
            }
        }
    }

    private func page(_ selectedTab: DashboardTab) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let snapshot = store.snapshot {
                        sourceHeader(snapshot)
                        if selectedTab == .limits {
                            let providers = snapshot.providers.filter(\.hasConnectedLimits)
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                VStack(spacing: 16) {
                                    ForEach(providers) { provider in
                                        CompanionLimitsCard(
                                            provider: provider, now: context.date,
                                            showRemaining: showRemaining)
                                    }
                                    if providers.isEmpty {
                                        ContentUnavailableView(
                                            "No connected providers", systemImage: "chart.bar",
                                            description: Text(
                                                "Set up your coding tools on the Mac to see limits here."
                                            ))
                                    }
                                }
                            }
                        } else {
                            CompanionActivityView(
                                activity: snapshot.activity, range: $range,
                                cost: selectedTab == .cost)
                        }
                        Label(
                            "Collected on your Mac. Pull to refresh from iCloud.",
                            systemImage: "icloud"
                        )
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else {
                        welcome
                    }
                    if let message = store.message {
                        Label(message, systemImage: "icloud.slash").font(.footnote)
                            .foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    if let message = store.subscriptionMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
                    .frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .background(Color.companionCanvas)
            .navigationTitle("Usage Meter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "slider.horizontal.3") { showSettings = true }
                }
            }
            .refreshable { await store.refresh() }

        }
    }

    private func sourceHeader(_ snapshot: CompanionSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ComputerIconButton(sourceID: snapshot.sourceID, name: snapshot.sourceName)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.sourceName).font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text("Synced")
                    Text(snapshot.publishedAt, style: .relative)
                    Text("ago")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
            } else {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "desktopcomputer.and.arrow.down").font(.system(size: 48))
                .foregroundStyle(.tint)
                .padding(.top, 36)
            Text("Your usage.\nWithin reach.").font(.largeTitle.bold())
            Text("Limits, tokens, and cost from your Mac. A quick glance, wherever you are.")
                .font(.title3).foregroundStyle(.secondary)
            CompanionCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Enable iCloud sync on your Mac", systemImage: "1.circle")
                    Label("Use the same Apple Account", systemImage: "2.circle")
                    Label("Scan the Mac’s connection code", systemImage: "3.circle")
                    Button("Connect your Mac", systemImage: "qrcode.viewfinder") {
                        showConnection = true
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                }.font(.subheadline)
            }
            Button("Discover Macs in iCloud", systemImage: "icloud") {
                Task { await store.refresh(discoverSources: true) }
            }
            .frame(maxWidth: .infinity)
            ForEach(store.sources) { source in
                Button(source.sourceName, systemImage: "desktopcomputer") {
                    Task { await store.connect(CompanionLink.url(sourceID: source.sourceID)) }
                }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CompanionSettings: View {
    let store: CompanionStore
    @Binding var showRemaining: Bool
    let requestConnection: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Display") { Toggle("Show remaining quota", isOn: $showRemaining) }
                Section("Connected Mac") {
                    if let snapshot = store.snapshot {
                        HStack {
                            ComputerIconButton(
                                sourceID: snapshot.sourceID, name: snapshot.sourceName)
                            Text(snapshot.sourceName)
                            Spacer()
                        }
                    }
                    Button("Connect another Mac", systemImage: "qrcode") {
                        requestConnection()
                    }
                    if store.snapshot != nil {
                        Button("Disconnect and clear readings", role: .destructive) {
                            confirmDisconnect = true
                        }
                    }
                }
                Section {
                    Text(
                        "When your Mac sleeps, readings stop updating. Widgets refresh when iOS allows."
                    )
                    Text(
                        "Tokens and API-equivalent cost come from local session logs. Cost is an estimate, not your subscription bill."
                    )
                    Text(
                        "Your private iCloud contains summaries only. Credentials, prompts, paths, and session logs stay on the Mac."
                    )
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Disconnect this Mac?", isPresented: $confirmDisconnect) {
                Button("Disconnect and clear readings", role: .destructive) {
                    store.disconnect(); dismiss()
                }
            } message: {
                Text("This clears this phone’s readings. Cloud data is managed on your Mac.")
            }
        }
    }
}
