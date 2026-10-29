# iOS companion: research and implementation recommendation

Research date: October 11, 2026. This is an architecture recommendation based on repository inspection, current product documentation, and platform documentation. No companion prototype, provider authentication experiment, or device-to-device latency measurement has been performed. Product claims below are attributed to their developers; they are not independent security audits.

Implementation follow-up: the first Limits/widget companion now exists; see [setup and validation](ios-companion-setup.md). Its initial single-writer transport uses explicit CloudKit record operations, a persisted Mac outbox, and zone-change discovery rather than CKSyncEngine. This keeps the small snapshot protocol independent of a two-way synchronization engine. History remains a later phase.

## Decision

Build a Mac-powered, read-only iOS companion backed by private CloudKit snapshots. Offer a QR code in the menu bar to select the source Mac, alongside automatic discovery of Macs in the same iCloud account. Use iCloud as the transport, rather than requiring a direct connection to the Mac.

This recommendation assumes an Apple-only personal utility, the same Apple Account on both devices, and a preference for avoiding an operated backend. Different Apple Accounts, an eventual Android client, or dependable server-originated threshold alerts would change the decision toward an encrypted relay.

QR onboarding is compatible with this design, but it is not its security boundary. iCloud account authentication controls access. The QR identifies the Mac and simplifies setup; it cannot grant a phone on a different Apple Account access to the private database. Do not describe scanning as cryptographic device authorization.

## What the existing app makes possible

The Mac already normalizes provider results into Codable `ProviderUsage`, `UsagePool`, and `UsageWindow` values. Those include capture timestamps, reset times, plans, and reset-credit counts. Reuse a deliberately restricted export schema rather than serializing every internal property or raw error message.

The collectors are desktop-specific: Claude invokes a Node/Agent SDK helper; Codex invokes its app-server; Gemini reads desktop sign-in credentials. Keeping collection on the Mac avoids developing and maintaining three additional iOS authentication integrations. This does not remove the existing collectors' upstream dependencies.

Activity comes from local Claude Code and Codex logs. `ActivityStore` currently scans on demand; enabling history sync must explicitly enable scheduled incremental scans even when nobody opens the Mac's activity tabs. It cannot simply publish the store's current summary, which may be absent or represent only the selected range.

The build is a SwiftPM executable assembled by `build.sh`, distributed with Developer ID signing and without App Sandbox. Its entitlements currently contain no CloudKit capability. CloudKit is supported for Developer ID applications, so a Mac App Store migration is not necessary. Provisioning, container registration, embedded profile handling, and release signing need actual changes and testing. [Apple: Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)

## Options considered

| Option | Away from home | Mac offline | Setup | Main tradeoff | Decision |
|---|---|---|---|---|---|
| Direct provider access on iPhone | Yes, with network | Can fetch account limits | Provider sign-ins on phone | New auth and provider integrations; no access to Mac logs | Defer |
| QR + local TLS/Bonjour | Only with an additional remote route | Phone cache only | Scan plus local-network permission | Network topology and Mac reachability become product problems | Not the default |
| QR + Tailscale or user-configured tunnel | Yes, with configured connectivity | Phone cache only unless storage is added | Extra software/account/network setup | Good developer option; substantial mainstream friction | Optional future mode |
| Private CloudKit + Mac selection/QR | Yes, with network | Last cloud snapshot remains available | Same Apple Account; opt in | iCloud dependence and eventual delivery | Recommended |
| QR + encrypted custom relay | Yes, with network | Stored encrypted snapshot remains available | Scan and approve | Backend, pairing protocol, recovery, abuse prevention, and operations | Runner-up |
| CloudKit plus direct LAN acceleration | Yes via iCloud | Last snapshot | Both sets of setup | Two transports and inconsistent freshness paths | Defer until justified |

### Direct provider access

This is real, not merely hypothetical. Usages documents iPhone-to-provider connections, Keychain credentials, and optional private iCloud sync. Its Mac companion separately supplies log-derived model/token history. This is a useful precedent for a hybrid product. [Usages support](https://usages.app/support/), [Mac companion](https://usages.app/mac/)

Usage for Claude's version 3 release notes also describe independent sign-in on iPhone. Its general listing still contains older Mac-companion descriptions, so the version history is the clearer evidence for current standalone behavior. [App Store listing](https://apps.apple.com/us/app/usage-for-claude/id6755173244)

An inspectable example, Claude Usage Monitor, documents embedded web sign-in, session-cookie storage in Keychain, and requests to Claude's internal usage endpoint. Its README explicitly says the endpoint is undocumented and unversioned. This proves one possible mechanism, not that all commercial apps use it or that equivalent supported mobile integrations exist for all three of our providers. [Project README](https://github.com/MarkRWatts/ClaudeUsageMonitor/blob/main/README.md)

Reject as the first implementation because it duplicates provider integration work and cannot replace the Mac for local history. Reconsider if independent phone refresh becomes more important than effortless onboarding. A future hybrid should clearly identify which source produced each reading and prevent older Mac snapshots from overwriting newer direct observations.

### Local QR pairing

Proposed implementation: a Mac `NWListener`, a specific Bonjour service, TLS with the Mac identity pinned from the QR, and an expiring enrollment challenge. The phone creates its own identity; the Mac approves enrollment and records a per-device credential. Never put a permanent bearer credential in a QR or disable certificate verification globally.

Bonjour handles local discovery, not internet reachability. Direct LAN networking requires privacy declarations and permission handling; guest networks, client isolation, firewalls, and changed addresses require recovery paths. Apple documents the relevant `NSLocalNetworkUsageDescription` and `NSBonjourServices` requirements. [Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

This is attractive for strict local-only users. For checking usage away from the desk, it needs another route, and a QR alone supplies none. A sleeping Mac cannot be treated as an available server; wake-on-network behavior would need separate validation and should not be promised.

### Tailscale or a tunnel

A user-managed VPN can make the Mac reachable remotely. Tailscale's iOS setup requires its separate app, a VPN configuration, and sign-in; it supports automatic VPN connection policies. Use an explicit configured remote hostname/address rather than assuming local Bonjour discovery crosses the VPN. [Tailscale iOS installation](https://tailscale.com/docs/install/ios), [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)

Tactic Remote demonstrates the broader computer-companion pattern: its current site describes same-network code scanning and a relay path for bound computers. Its goal includes interacting with running agents, where an online computer connection has more value than it does for a usage snapshot viewer. [Tactic Remote](https://tacticremote.com/)

A tunnel is a route to a live Mac, not durable storage. Do not expose an unauthenticated usage endpoint through it. Reject as a default due to setup and reachability complexity; keep it as a possible advanced/local-only option.

### Private CloudKit

The CodexBar iOS fork explicitly requires its Mac companion and receives snapshots through iCloud. Its privacy documentation identifies CloudKit, the same Apple ID, and per-Mac records. This is the closest existing precedent to our proposed architecture. [App Store listing](https://apps.apple.com/us/app/codexbar-usage-of-ai/id6760216772), [project privacy documentation](https://github.com/o1xhack/CodexBar-Mobile/blob/mobile-dev/PRIVACY.md)

Private CloudKit requires iCloud and normally the same account across devices. The developer cannot inspect the user's private database in the developer portal, and its data counts toward the user's storage quota. Cross-account CloudKit sharing is possible, but would add sharing UI and lifecycle work; a source-ID QR does not replace that mechanism. [Private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), [CloudKit sharing](https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users)

Its strength is durable delivery without operating our own account service or relay. Its limitation is eventual synchronization, not a guaranteed live channel. CloudKit encrypted fields are available; prefer them for usage payloads and leave only necessary routing/version metadata unencrypted. Do not claim Apple-independent end-to-end secrecy: Apple's documentation ties exclusive owner access to encryption keys to Advanced Data Protection. [Encrypted record values](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)

### Encrypted custom relay

This best matches genuine scan-to-authorize pairing across unrelated accounts. Both devices connect outbound; the relay stores encrypted snapshots so the phone can read while the Mac is offline. It also supports future non-Apple clients and server-originated APNs alerts.

Happier documents a relevant pattern: local encryption keys, a relay holding ciphertext, and QR enrollment followed by approval on an existing device with a confirmation code. It is a design precedent, not a protocol to copy without review. [Happier security architecture](https://happier.dev/security/)

If chosen, implement one-use pairing requests with short expiry, device public keys bound to the QR invitation, approval on the Mac, distinct read/write authorization, replay prevention, revocation, and key rotation. Store only encrypted usage summaries and a bounded history. Losing all authorized devices would require re-pairing; plan recovery without silently weakening encryption.

Cloudflare Workers plus a SQLite-backed Durable Object is a plausible implementation, with HTTPS for snapshot writes/reads and a WebSocket only if online refresh commands become necessary. Hibernation can reduce idle WebSocket charges, but requests, storage, and active execution still matter. No workload-specific cost estimate has been measured. [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)

Reject for version one because a usage dashboard does not yet justify operating identity, encrypted storage, pairing, APNs credentials, retention, rate limits, monitoring, and support. Choose it instead if different Apple Accounts or prompt remote alerts are firm requirements.

## Recommended user experience

1. On the Mac, select **Connect iPhone** from the menu bar. Explain that usage summaries will sync through personal iCloud, then enable publishing.
2. Show the source Mac's QR and a last-upload status. The code contains an app-specific format/version and random source ID, without account names, provider tokens, or network credentials.
3. On iPhone, scan in the app or choose from Macs discovered in the private database. Camera permission is only needed for scanning; discovery is an equally supported alternative.
4. Verify the source exists in the phone's private database. If not, show an actionable same-account/iCloud/upload check rather than waiting indefinitely. Scanning does not bypass account access.
5. Show **Connected to [Mac]**, provider-specific observation ages, and whether history sync is enabled. Avoid claiming that a fresh upload proves a provider reading is fresh.
6. Phone pull-to-refresh fetches cloud changes. It does not promise to wake the Mac or force upstream polling. If later adding a remote refresh request, describe it as pending until the Mac acknowledges it and respect provider throttling.

Disabling sync on the Mac stops publishing. Provide an explicit delete-cloud-data action separately. Removing a source on the phone stops displaying it; it cannot revoke access for another device already authorized through the same iCloud account. Device-level cryptographic revocation is a custom-pairing requirement, not a feature this initial design claims.

## Concrete implementation

Use a shared Foundation-only Swift package for snapshot DTOs, usage windows, formatting, and pace calculations. Keep AppKit, subprocesses, CLI discovery, and desktop credential access in the Mac target. Add an Xcode project for the iOS app and WidgetKit extension; choose iOS 17+ for a first implementation aligned with CKSyncEngine and the current macOS 14 baseline.

Create a shared CloudKit container and a custom private record zone. Use `CKSyncEngine` behind a small sync service, persist its state and pending changes, and explicitly send after a coalesced Mac update or fetch when the phone opens. Handle account changes by clearing the previous account's cache and sync state. Apple provides automatic scheduling and explicit send/fetch APIs, but timing remains indeterminate. [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9)

Proposed records:

| Record | Contents | Writer |
|---|---|---|
| Source | Random installation ID, display name, schema version, last publication | Mac |
| Provider snapshot | Source/provider ID, successful observation time, windows, status, monotonic revision | Mac |
| Activity bucket | Source/provider/model, UTC interval start/end, token components, estimated cost and pricing revision | Mac |

The latest provider reading and publication timestamp are distinct. Sanitize failure states into small status enums; don't upload paths or arbitrary CLI stderr. Old snapshots must never become fresh merely because they were uploaded again. On reset, show that a new reading is needed rather than inventing a 0% value.

Version one selects one source Mac. Do not sum account-level limit percentages. Do not merge multiple Macs' log totals automatically: copied logs can overlap, and pre-aggregated buckets cannot fully deduplicate across machines. A later multi-Mac feature needs explicit source scopes or stable event identities.

Start with Limits and small/medium Home Screen widgets. Add history afterward using hourly UTC buckets over 90 days, acknowledging that hourly aggregation approximates a rolling 24-hour boundary and can misalign with unusual timezone offsets. Export a separate history schema rather than the selected `ActivitySummary`. Preserve the label **API-equivalent estimate**, unknown-price coverage, and pricing provenance.

Publish changed limits after existing collector refreshes, coalescing writes around the app's current one-minute loop. Initial history proposal: incremental scan and changed-bucket upload every five minutes while enabled and awake; benchmark cold scans before committing to that cadence. Retry offline uploads with backoff. Sync failure must not block local collection or the menu UI.

Share a bounded phone cache with the widget through an App Group. The app fetches on foreground entry and pull-to-refresh; background sync is opportunistic. Let the widget render its last snapshot and reset countdowns without requiring an active socket. Apple controls widget reload budgets. [Widget update guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/)

Do not promise precise threshold alerts in version one. CloudKit change notifications can prompt fetching, but are coalesced and are not an event log. iOS silent pushes are discretionary; a custom relay also cannot guarantee background execution or widget updates. Reset reminders can be scheduled locally from known times, with cancellation when readings change. Prompt threshold alerts would require a separately evaluated visible remote-notification path. [CloudKit subscriptions](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription), [Apple background push guidance](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

## Validate before building the full interface

The first engineering milestone should be a signed sync spike, not a polished dashboard:

- Publish one synthetic snapshot from a Developer ID Mac build and read it from a TestFlight iPhone build using the production container.
- Repeat over cellular, with the Mac subsequently asleep, and after both apps restart.
- Measure Mac upload-to-foreground-fetch latency and observe background/widget behavior separately; don't turn observed timings into delivery guarantees.
- Test iCloud signed out, different accounts, network loss, exhausted storage, delayed writes, stale readings, source deletion, account switching, and schema mismatch.
- Verify no provider secrets, raw logs, project paths, or unsanitized errors enter the export.
- Then connect the real collectors and check that provider throttling, stale-value behavior, and menu performance still work.

If this spike proves problematic in the actual distribution pipeline, investigate and quantify the signing/sync issue before substituting a custom relay. CloudKit's documented Developer ID support means the current distribution method alone is not a reason to abandon it.

The resulting first release has a clear promise: see the latest usage collected by your Mac from anywhere, with honest freshness information, without another provider login or a network server to configure. QR scanning remains a convenient way to select that Mac.

### Implemented history follow-up

The phone now includes Tokens and Cost. Instead of approximate hourly UTC
history, the Mac exports four exact summaries using its existing aggregator
(24h, 7d, 30d, 90d), each pinned to the scan timestamp and Mac calendar/time zone.
This preserves agreement with the menu-bar figures and allows offline range
selection with a small bounded payload. The tradeoff is that an offline rolling
window remains frozen at its observation time; the phone labels that age rather
than pretending to recalculate from response-level records. Scheduled incremental
scans run on the existing one-minute refresh cadence only while companion sync
is enabled. Pricing provenance and unknown-price coverage accompany the estimate.
A separate configurable Tokens & Cost widget uses the same shared-cache protocol.
