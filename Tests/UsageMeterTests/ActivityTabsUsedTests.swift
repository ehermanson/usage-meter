import Foundation
import Testing

@testable import UsageMeter

/// Whether the Tokens and Cost tabs have been used, which is what lets
/// opening the panel (and a Claude folder change) scan the session logs.
@Suite("Activity tabs used")
struct ActivityTabsUsedTests {
    @MainActor
    @Test("picking Tokens or Cost marks the tabs used, for good; picking Limits doesn't")
    func notesActivityTabs() {
        let store = UsageStore.shared
        let key = UsageStore.activityTabsUsedKey
        let defaults = UserDefaults.standard
        let saved = (store.hasUsedActivityTabs, defaults.object(forKey: key))
        defer {
            store.hasUsedActivityTabs = saved.0
            // The setter always writes; put back "never set" if it was.
            if saved.1 == nil { defaults.removeObject(forKey: key) }
        }

        for tab in [UsageTab.tokens, .cost] {
            store.hasUsedActivityTabs = false
            store.noteTabSelected(.limits)
            #expect(!store.hasUsedActivityTabs)
            #expect(!defaults.bool(forKey: key))

            store.noteTabSelected(tab)
            #expect(store.hasUsedActivityTabs, "\(tab)")
            #expect(defaults.bool(forKey: key), "persisted for the next launch")

            store.noteTabSelected(.limits)
            #expect(store.hasUsedActivityTabs, "going back to Limits keeps it")
        }
    }

    @MainActor
    @Test("the logs are scanned ahead once the tabs are used, or when `--tab` opens on one")
    func scansAhead() {
        let store = UsageStore.shared
        let key = UsageStore.activityTabsUsedKey
        let defaults = UserDefaults.standard
        let saved = (store.hasUsedActivityTabs, defaults.object(forKey: key))
        defer {
            store.hasUsedActivityTabs = saved.0
            if saved.1 == nil { defaults.removeObject(forKey: key) }
        }

        store.hasUsedActivityTabs = false
        #expect(!store.scansActivityAhead(launchTab: nil))
        #expect(!store.scansActivityAhead(launchTab: .limits))
        // Opened straight onto the tab, which no pick ever marks.
        #expect(store.scansActivityAhead(launchTab: .tokens))
        #expect(store.scansActivityAhead(launchTab: .cost))
        #expect(!store.hasUsedActivityTabs, "a launch tab isn't a pick")

        store.hasUsedActivityTabs = true
        for tab in [nil, UsageTab.limits, .tokens, .cost] {
            #expect(store.scansActivityAhead(launchTab: tab), "\(String(describing: tab))")
        }
    }
}
