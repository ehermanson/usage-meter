# Companion development and release setup

The companion includes Limits, Tokens, and Cost dashboards, QR scanning/link paste,
automatic Mac discovery, selectable small/medium Home Screen widgets, explicit
foreground refresh, opportunistic background refresh, and source/cache removal.
It exports provider windows, plan labels, status enums and observation timestamps.
It does not export credentials, raw session logs, paths or CLI error text.
Threshold notifications remain future work.

## Generate and build

Install XcodeGen and generate the project:

```sh
brew install xcodegen
xcodegen generate --spec iOS/project.yml
open iOS/UsageMeterCompanion.xcodeproj
```

Generated `.xcodeproj` files are ignored; `iOS/project.yml` is authoritative.
The project has `UsageMeterMac`, `UsageMeterCompanion`, and `UsageMeterWidgets`
targets. The phone and widget use the root package's `CompanionKit` library.
The Mac Xcode target uses the same collectors and UI as the SwiftPM/DMG build,
with provider marks copied into its main resource bundle and the Node helper
bundled by a build script. It is not sandboxed.

The configured developer team is `2YN57RAL6Q`. Automatic signing must authorize:

| Target | Bundle ID | Capabilities |
|---|---|---|
| Mac | `com.erichermanson.usagemeter` | CloudKit, hardened runtime |
| iPhone | `com.erichermanson.usagemeter.ios` | CloudKit, App Group, push notifications, background fetch/remote notifications |
| Widget | `com.erichermanson.usagemeter.ios.widgets` | CloudKit, App Group |

Both platforms use `iCloud.com.erichermanson.usagemeter`; phone and widget share
`group.com.erichermanson.usagemeter`. If adapting for another team, update the
Swift configuration, project spec, entitlements and profile validator together.

Build the phone without signing for Simulator:

```sh
xcodebuild -project iOS/UsageMeterCompanion.xcodeproj \
  -scheme UsageMeterCompanion -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Use `--companion-demo` as a launch argument for an isolated phone UI preview.
It shows synthetic readings without CloudKit requests or persistent cache writes.
Remove that argument for real pairing. QR scanning needs a supported physical
device and camera access; link paste and Mac discovery also work without a camera.

## CloudKit schema and environments

Signed Debug builds use the CloudKit Development environment. Developer ID/DMG
and TestFlight/App Store builds use Production. Devices must use the same
environment as well as the same Apple Account; a QR cannot bridge either boundary.

The service uses a custom private record zone named `Companion`. Each source Mac
writes one `UsageSnapshot` record whose record name is a random installation UUID.
The record has one encrypted Bytes field, `payload`, containing the versioned
JSON envelope. Mac discovery fetches paginated zone changes from the beginning,
so there are no required query indexes. Reading a selected Mac uses its record ID.
Change notifications use a zone subscription and are a hint to fetch, not an event
log or a delivery guarantee.

Run the synthetic signed-Mac check once to create the Development schema:

```sh
path/to/UsageMeter.app/Contents/MacOS/UsageMeter --companion-sync-check
```

It checks iCloud account availability, uploads a synthetic provider snapshot,
fetches and verifies it, then deletes its test record. It never reads CLI
credentials or session logs. On failure it attempts cleanup and reports the error.

For a phone integration check, add `--hold-for-phone`. It prints a connection
link and keeps the synthetic snapshot available for two minutes before deleting
it. In a Debug phone build, `--companion-reset-cache` clears diagnostic selections.

Before distributing release builds, deploy this schema from Development to
Production in [CloudKit Console](https://icloud.developer.apple.com/). Confirm
`payload` is encrypted from its creation; an existing plaintext field cannot be
converted in place. No user data is migrated by schema deployment. Test a signed
Production Mac build against a TestFlight phone after deployment. Publishing
the schema and uploading to TestFlight are separate release steps; building
locally does not perform them.

## Existing Mac build and release pipeline

`./build.sh` still produces a usable ad-hoc build by default. Such builds show
the iPhone connection entry in settings, but cannot enable sync without the
required CloudKit provisioning. They never construct an unentitled CloudKit container.

For a CloudKit-enabled DMG build, provide a Developer ID provisioning profile
authorizing the Mac bundle ID, CloudKit container and Production environment:

```sh
export CODESIGN_IDENTITY='Developer ID Application: Eric Hermanson (2YN57RAL6Q)'
export COMPANION_PROVISIONING_PROFILE='/absolute/path/UsageMeter.provisionprofile'
./build.sh
```

The build validates the profile, embeds it in `Contents/embedded.provisionprofile`,
signs with `UsageMeter-Cloud.entitlements`, and marks the bundle cloud-enabled.
Keep profiles and certificates out of source control. The release workflow accepts
an optional `COMPANION_PROFILE_BASE64` secret; without it the existing signed DMG
pipeline remains cloud-disabled. Use a **Developer ID** profile for distribution,
not the Mac Team development profile created by Xcode.

## Data and lifecycle behavior

Sync is opt-in on the Mac. A verified account owns the persisted latest pending
upload; account changes stop publishing and clear the outbox until opt-in again.
Updates are serialized, coalesced, revisioned, and retried with exponential/server
backoff during the existing collection loop. A failed upload does not block local
provider collection. Each provider retains its actual observation timestamp.

The phone explicitly selects one source. It does not sum quota percentages or
merge multiple Macs' potentially overlapping logs. QR links only carry protocol
version and source UUID; iCloud authorizes access. A fetched private record must
match the scanned ID before the phone connects.

The App Group cache is written atomically under a cross-process file lock. Widget
responses cannot undo a phone disconnect, source switch or account change, and
older revisions cannot overwrite newer readings. Cache data is protected until
the first device unlock. Account-change notifications clear saved data; the phone
checks account identity before exposing restored readings. No-account and deleted
source responses clear widget data. Transient network errors retain prior data.

Readings become visibly stale after ten minutes and expire after a day. A reset
time passing never implies a new 0% reading; the app says it needs a new observation.
Widget timelines request updates after fifteen minutes, but iOS chooses actual
delivery. Background fetch and CloudKit silent pushes are best-effort. No exact
threshold-alert promise is made.

Disabling Mac sync stops new writes but retains the last cloud record. **Delete
this Mac's cloud data** waits for an in-flight upload to finish before deleting,
so that upload cannot recreate the deleted record. Cached phone data is cleared
by **Disconnect and clear saved readings**. Source removal is not cryptographic
revocation of another device on the same Apple Account.

## Validation

```sh
swift test
swift format lint --recursive --strict --configuration .swift-format Sources Tests iOS/UsageMeter iOS/UsageMeterWidgets
```

The companion tests cover export sanitization, strict connection-link parsing,
schema rejection, observation age, reset boundaries, revision ordering, atomic
cache round trips and stale widget responses after source/account changes.
CI builds the iOS app and its widget for Simulator.

During implementation, signed Mac and iPhone builds passed, the synthetic Mac
publish/fetch/delete check succeeded in Development, and the paired physical
iPhone received the synthetic provider via a connection deep link. The phone
test cache was then cleared. Simulator layout was inspected with isolated demo
data. Physical camera QR scanning, Home Screen widget placement, cellular/sleep
behavior and Production/TestFlight remain acceptance checks.

Device acceptance checks: signed Mac upload and phone fetch; QR and discovery;
cellular access; Mac asleep; offline retry; account sign-out/switch; cloud deletion;
widget source/provider selection; first-unlock behavior; denied camera access;
schema mismatch; Production/TestFlight environment alignment. These require real
devices and iCloud accounts; a successful compiler build alone cannot verify them.

### Astra architecture review

Astra reviewed the implementation and research on October 11, 2026. The private
CloudKit snapshot architecture, Mac-owned persisted outbox, and same-account QR
source selection remain appropriate for the first release. No sync-engine or relay
redesign was recommended.

The review led to conditional shared-cache refreshes in the phone as well as the
widget, re-reading shared selection after widget network operations, clearing
cached identity on CloudKit authentication failures, discovery while already
connected, and selecting/displaying the tightest quota across all windows.

Deliberate v1 tradeoffs: the phone verifies identity before displaying restored
cache; widgets retain cached readings during transient verification failures.
iOS may leave an already-rendered widget visible until its next update. Future
schema versions should isolate incompatible discovery records. A source reset
or writer-generation mechanism should precede support for cloned/restored Mac
preferences, which can duplicate UUIDs or roll back revision counters.

Production CloudKit schema, Developer ID provisioning, and TestFlight smoke
checks above remain required before distributing companion support. The release
pipeline without its optional companion profile still builds a cloud-disabled DMG.

### Tokens and Cost

The phone now includes Limits, Tokens, and Cost views. While companion sync is
on, the Mac scans session logs in the background on its existing refresh cadence
and exports all four history ranges: rolling 24h, and 7/30/90 calendar days
including today. The Mac's existing deduplication and model-price calculations
produce provider totals, distinct-session counts, unpriced-token counts, and
hourly/daily buckets. Only those aggregates enter private CloudKit; model
responses, prompts, session identifiers, and file paths have no export fields.

Cost is USD API-equivalent cost, not subscription billing. Unknown model prices
are excluded from cost and identified in the phone UI. Ranges are frozen at the
history observation time, and calendar buckets use the Mac's time zone. Offline
range changes do not recalculate a rolling window against the phone's clock.
History has its own observation timestamp, so a new limits upload cannot make an
old history scan appear fresh. The optional `activity` field is additive to
schema 1: existing limits-only clients ignore it, and new phones accept snapshots
from older Macs with a waiting-for-activity state. Data remains bounded to four
ranges, 100 buckets per range, and 16 providers within the existing 512 KB limit.

The Tokens & Cost Home Screen widget supports both metrics and all four ranges.
Tapping it opens the selected tab and range. Existing Limits widgets keep their
configuration. Widget updates remain opportunistic and retain observation ages.

### Widget visual checks

Widgets share their content views and provider assets with the app in `iOS/Shared`.
The medium Limits widget shows two complete quota rows with provider branding,
reset countdowns, and a compact freshness footer. Fixed provider selection retains
its Mac window order; the small widget leads with that provider's tightest quota.
Tokens & Cost uses the same header/footer system with a medium-size sparkline.
Local timeline entries advance compact ages when network refresh is delayed.

A Debug-only `--companion-demo --widget-design-preview` launch shows the actual
shared views at small/medium sizes with synthetic values. This is a layout check,
not a substitute for Home Screen placement and WidgetKit scheduling checks.
Reference captures are [light](ios-widgets-light.png) and [dark](ios-widgets-dark.png).
Gallery/placeholder samples never enter the cache or CloudKit.

### Interactive widget buttons

Limits widgets have native App Intent controls: connected-provider logo buttons
on medium widgets, and a next-provider arrow on small widgets with multiple
providers. Providers needing setup or lacking limit readings are hidden in the
controls and app Limits cards. Temporary failures retain providers with saved
readings. There is no Auto button; legacy Closest to limit configurations remain
compatible until a provider is selected. Tokens & Cost widgets have a two-button metric selector at both sizes.
They change the displayed summary without opening the app or requesting a Mac
scan. Observation times and stale indicators retain their original meaning.

Selections live in the app group, keyed by saved widget configuration. Limits
uses the configured provider; activity uses the configured metric and range.
Differently configured widgets in a stack remain independent. Copies with
identical configurations share their last button selection. A configuration
change uses the selection stored for that configuration, or its default when
none exists. Button parameters and stored values are restricted to known choices.

After a tap, timeline generation uses the current shared cache for 30 seconds,
avoiding a CloudKit round trip on the interaction path. Normal scheduled refresh
resumes afterward. The intent reloads the affected widget kind and keeps the
existing source/account cache transactions. Development-gallery controls are
inert and do not modify real widget preferences.

### Freshness recovery

The foreground iPhone app checks CloudKit every minute and cancels polling when
it leaves the foreground. The Mac refresh timer runs in common run-loop modes
and refreshes immediately after waking. iCloud account notifications trigger
identity verification rather than unconditionally disabling Mac sync or removing
the iPhone’s selected source. Actual account changes still clear account-bound
data and require opting in again on the Mac. Temporary cloud failures retain the
account-bound outbox for retry. Provider capture times are never advanced merely
because a cached snapshot was downloaded.

The Mac must be awake and running to collect new readings. Home Screen widget
updates and background iPhone checks remain scheduled by iOS.

### Mac connection UI

Connect iPhone is hidden by default. Enable it locally with
`defaults write com.erichermanson.usagemeter companion.showConnectionUI -bool true`
and restart the app. The preference survives normal updates and is only a UI
visibility setting; iCloud account authorization still protects readings.
Cloud sync still requires
`CompanionCloudEnabled` and the appropriate provisioning profile. Builds without
CloudKit support show a configuration message when sync is requested.

### Production verification (October 29, 2026)

The schema was deployed to Production. A Developer ID Mac build passed the
synthetic publish/fetch/delete check, then uploaded real summaries. The iPhone
app and widget were archived and exported with Ad Hoc profiles for Production,
installed locally, and the owner confirmed syncing works. The Mac provisioning
profile is stored in the repository’s `COMPANION_PROFILE_BASE64` Actions secret.
No public release or TestFlight upload was performed.

For repeat local iPhone exports, archive the Release scheme and export using
`release-testing`, manual Apple Distribution signing, Production iCloud, and
separate Ad Hoc profiles for the app and extension. Signing assets and generated
export options stay outside source control. Profiles must include the target
iPhone and authorize the shared iCloud container and app group.
