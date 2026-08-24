# cmux agent notes

## Setup

`./scripts/setup.sh` initializes submodules, builds GhosttyKit, and installs the pbxproj normalization pre-commit hook.

## Build and reload

Always build with a tag. **Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`**: untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <branch-slug>            # build Debug, kill same-tag app, do not launch
./scripts/reload.sh --tag <branch-slug> --launch   # also open it
```

<!-- SUPERMUX:begin dogfood-direct-launch-link -->
A tag gives the app its own name, bundle ID, socket, derived data path, and direct URL scheme, so it
runs side-by-side with the user's main app. Before handing off a build made without `--launch`,
register the printed `App path:` with LaunchServices without opening it:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "<App path printed by reload.sh>"
```

Then report the build as a direct Markdown link:
`[Open <tag>](cmux-dev-<tag>://launch)`. Cmd-clicking it launches the tagged app directly without a
browser or local HTTP server. Use the normalized tag slug printed by `reload.sh`; `--launch` also
registers the scheme automatically. Never use the old `http://127.0.0.1:17320/<tag>` Tag Opener
link, and never put a `file://` URL, raw `.app` or DerivedData path, or `/tmp/cmux-<tag>/...` in chat
output. Keep the host `launch` rather than `auth-callback`, which is reserved for sign-in.
<!-- SUPERMUX:end dogfood-direct-launch-link -->

Other variants: `reloadp.sh` (Release), `reloads.sh` (Release as isolated "cmux STAGING"), `reload2.sh --tag <tag>` (both).

## Shared Mac fleet capacity

Every healthy slot in the canonical Mac fleet is general-purpose. Builds, iOS archives, tests, profiling, simulator and UI verification, and any other resource-intensive workload may use any available slot. Do not wait for an AWS-only builder or infer capacity from a workload label. Use the shared lease state and slot-isolated paths supplied by the fleet tooling.

Compile-only check, no launch:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

Rebuild GhosttyKit.xcframework with Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

Clean up older tags you started this session (quit the app, remove its `/tmp` socket and derived data) before launching a new one.

<!-- SUPERMUX:begin mac-dogfood-supermux-profile -->
### Supermux: Mac dogfood builds the user opens use `--supermux-profile`

A plain `reload.sh --tag` build points sign-in at a localhost dev web origin nothing serves, so the
user cannot log in to it. For any tagged Mac build the **user** will open and test, add
`--supermux-profile`:

```bash
./scripts/reload.sh --tag <branch-slug> --supermux-profile            # user dogfood build
./scripts/reload.sh --tag <branch-slug> --supermux-profile --launch
```

It implies `--prod-auth` (production Stack auth + cmux.com APIs) and seeds the tag's isolated
identity from the main installed Supermux release app (`com.supermux.app`): full UserDefaults
(settings/preferences) plus the Stack Auth `credentials.json`, so the build launches already
signed in as the user's real account with their real settings (`scripts/supermux-seed-dev-profile.sh`).
Stack Auth does not rotate refresh tokens, so both apps can run concurrently off the shared
session. **Never sign out inside a seeded build** — revoking the shared session signs the user's
main Supermux app out too. Agent-only builds (the user never opens them) keep using plain
`--tag` / the `~/.secrets` dogfood auto-sign-in.
<!-- SUPERMUX:end mac-dogfood-supermux-profile -->

## Tag-bound debug CLI

For CLI or socket dogfood against a tagged Debug app, set `CMUX_TAG` and use the helper. Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from DerivedData. It scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the tag.

## iOS UI follows the Apple HIG

`Packages/iOS/AGENTS.md` requires consulting the Apple Human Interface
Guidelines for any iOS UI change and citing the page in the PR. It applies to
`Packages/iOS/` and `ios/`.

## iOS builds open on the iPhone by default

Any work verified by opening the iOS app installs BOTH an isolated-simulator build AND the same build on the user's iPhone. Never stop at simulator-only. Use `ios/scripts/reload-cloud.sh --tag <tag>` (or `ios/scripts/reload.sh --tag <tag>`); with a default iPhone configured (`CMUX_IPHONE_DEVICE_ID` or `~/.config/cmux/iphone-device-id`) the device leg is automatic, and `--device-id <id>` still overrides (`xcrun devicectl list devices`). Physical iPhone builds always select the `personal` auth profile. Agent-driven Simulator verification always selects `agent`. Both named profiles live in `~/.secrets/cmuxterm-dev.env`; neither may fall back to the other. The simulator leg uses the tag's own isolated device `cmux-dev-<slug>`, created on demand; do not target a shared or user-visible simulator.

**Every phone install MUST be authenticated before handoff. Installed-but-signed-out is a failed install.** A tagged bundle id can retain an older account, so every authenticated launch clears that tagged session, signs both surfaces into the selected profile, verifies the exact tagged Mac account through `auth status`, then mints the pairing ticket. The iPhone auth gate passes only after the same-account host accepts the phone RPC and emits `mobile.rpc.ready`. `scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>]` repeats the Mac-account check, relaunches the phone without credentials, and passes only when persisted phone state reconnects. Never install with raw `devicectl device install app`, and never pass `--no-sign-in`/`--no-attach`/`--no-setup` for a dogfood build. The scripts refuse those device paths unless a human sets `CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1`. If setup fails, report the gate reason and exact retry command.

Every phone build requires the same-tag Mac dev build (the iOS app is unusable without its Mac). The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the signed build is parked in `scripts/iphone-install-queue.sh`. Each entry stores the chosen profile, normalized account, and credentials-file path. Drain revalidates that snapshot before device mutation and uses installed stable copies of the launcher and auth helpers, so an old or pruned feature worktree cannot change policy. Install or refresh that control plane with `scripts/install-iphone-queue-agent.sh install`. Report `scripts/iphone-install-queue.sh list` in the handoff; `drain` retries delivery and `clear` abandons a queued build.

## All fleet slots are general-purpose

Agent verification, macOS/iOS builds, archives, tests, profiling, and any other work too resource-intensive for the local Mac use the same Mac fleet. A slot is not a "build slot" or a "verify slot". From the cmuxterm-hq checkout that owns this worktree, every workload leases the canonical `~/.config/macfleet/hosts.json` inventory and shared `maclease` state.

Before waiting for a builder, run `scripts/macfleet-doctor.sh report --probe` from that hq checkout. If it reports `needs-sync`, run `scripts/macfleet-doctor.sh sync --apply`; it backs up the canonical manifest and merges legacy `hosts-verify.json` entries by SSH endpoint. Refresh the hq checkout before diagnosing capacity. Do not infer capacity from a stale checkout, one pool tag, or a remembered host list.

Agent verification runs on the fleet, not on the local Mac. `scripts/verify-remote.sh` leases a general-purpose slot, pushes the tagged build to the leased Mac, drives it there (per-lease uniquely named simulator for iOS; console launch with debug-socket and computer-use evidence for macOS), and fetches screenshots, recordings, and logs back into the hq `artifacts/verify-remote/` directory:

```bash
scripts/verify-remote.sh ios --tag <tag>
scripts/verify-remote.sh mac --tag <tag>
scripts/verify-remote.sh capacity             # all-purpose slots
```

Boot a local simulator only when all-purpose `capacity` reports no free slot, and keep at most 3 local sims booted. Scripted XCUITests go through the hosted `test-e2e.yml` lane when appropriate. The physical-iPhone signing/install leg stays local via the install queue; its archive build may use any healthy fleet slot. Verify leases carry a description and TTL, so a crashed agent frees its slot automatically; see `skills/infra/macfleet/references/verify-remote.md` in cmuxterm-hq for the shared-pool contract and host onboarding.

<!-- SUPERMUX:begin ios-dogfood-release-build -->
### Supermux: phone dogfood uses a Release build, not `reload.sh --tag`

The section above is upstream's workflow and does not work on this fork's phone. `reload.sh --tag`
builds **Debug** with `CMUX_DEV_TAG=<tag>`, and a tagged DEV iOS build may pair only with the
same-tag Mac **DEV** build — which the user cannot sign in to. That build installs fine and is then
unusable. `ios/scripts/reload-cloud.sh` does not exist in this checkout either.

So for anything the user must actually open on their iPhone, build Release against production auth:

```bash
xcodebuild -workspace ios/cmux.xcworkspace -scheme cmux-ios \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-<tag>" \
  -allowProvisioningUpdates \
  SUPERMUX_APP_BUNDLE_ID=com.supermux.ios.dogfood \
  SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements \
  SUPERMUX_NSE_CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements \
  SUPERMUX_IOS_DISPLAY_SUFFIX=" <tag>" \
  CMUX_GIT_SHA="$(git rev-parse --short=10 HEAD)" \
  CMUX_DEV_TAG= CMUX_PRESENCE_BASE_URL= CMUX_IOS_AUTH_ENV=production \
  EXCLUDED_SOURCE_FILE_NAMES=Info.plist \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=NRGUG8GVV4 \
  build

APP="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-<tag>/Build/Products/Release-iphoneos/cmux.app"
xcrun devicectl device install app --device <device-id> "$APP"
xcrun devicectl device process launch --terminate-existing --device <device-id> com.supermux.ios.dogfood
```

- `CMUX_DEV_TAG=` **empty** is what makes it official-compatible; the distinct
  `PRODUCT_BUNDLE_IDENTIFIER` is what keeps it beside the user's main install instead of replacing
  it.
- **The bundle id is FIXED at `com.supermux.ios.dogfood` for every dogfood build, every tag.**
  Never mint a per-tag bundle id (`dev.cmux.ios.<tag>` is the old scheme — retired). iOS sandboxing
  means login tokens and Mac pairing live per-bundle-id and cannot be copied from the main
  `com.supermux.ios` install (and keychain-group sharing with it is FORBIDDEN: the Iroh stores
  half-share and mutually wipe each other's relay credentials, breaking the user's main app). With
  one fixed dogfood id, the user signs in and pairs once, and every later dogfood build replaces it
  in place with login, pairing, and settings intact. `SUPERMUX_IOS_DISPLAY_SUFFIX` still carries the
  current tag, so the home-screen name says which build is installed.
- `DEVELOPMENT_TEAM=NRGUG8GVV4` is the personal team, which is also why
  `SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements` is required (touchpoint #53 strips
  the capabilities that team lacks).
- `SUPERMUX_NSE_CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements` points the notification service
  extension at the capability-free entitlements file, stripping the app group (#384) it carries by
  default. The dogfood extension id (`com.supermux.ios.dogfood.notification-service`) has no
  registered App ID, so it signs against the wildcard team profile, which has no App Groups
  capability; leave the default in and the build fails with *"Provisioning profile … doesn't support
  the group.com.supermux.ios App Group"*. Consequence: dogfood push banners show the generated
  avatar chip, not the real project logo — verify that path on the fixed-identity build
  (`scripts/supermux-ios-release.sh`), which owns registered App IDs and profiles.
  **Point it at a file; do not try to blank it.** A bare `SETTING=` is dropped by xcodebuild (the
  xcconfig default wins and the build still fails), while `'SETTING=""'` becomes the literal
  two-quote path `ios/""` and fails with *"The file … could not be opened"*.
- Resolve `<device-id>` from `CMUX_IPHONE_DEVICE_ID`, `~/.config/cmux/iphone-device-id`, or
  `xcrun devicectl list devices`. `install` works with the phone locked; `launch` fails with
  `BSErrorCodeDescription = Locked` — report that as "installed, tap to open", not as a failure.

**Never pass `PRODUCT_DISPLAY_NAME` on this command line.** A command-line build setting overrides
the xcconfig, so the app installs under whatever ad-hoc name the agent invented (this shipped a
build literally named "cmux Mobile Fix" and cost a round trip). The name comes from
`ios/Config/*.xcconfig`, where the fork already sets **Supermux**; leave it alone. The ONLY
sanctioned per-build naming knob is `SUPERMUX_IOS_DISPLAY_SUFFIX=" <tag>"` above (leading space,
quoted): the xcconfig templates `PRODUCT_DISPLAY_NAME = Supermux$(SUPERMUX_IOS_DISPLAY_SUFFIX)`,
so every dogfood install shows as "Supermux <tag>" on the home screen while official builds stay
"Supermux". Always pass it with the current build's `<tag>` (the bundle id stays fixed; the
suffix is what identifies the installed build). Same never-pass rule for
`ASSETCATALOG_COMPILER_APPICON_NAME` — a command-line override applies to every target in the
workspace and fails actool in the SwiftPM resource bundles.

A simulator leg is still worth building for a compile check, but target a concrete simulator
(`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`). `generic/platform=iOS Simulator`
fails to link: GhosttyKit ships no x86_64 simulator slice.
<!-- SUPERMUX:end ios-dogfood-release-build -->

## iOS dev auth

`~/.secrets/cmuxterm-dev.env` is the only mobile dev credential file. `CMUX_DOGFOOD_STACK_*` is the `personal` profile for physical iPhone dogfood. `CMUX_UITEST_STACK_*` is the `agent` profile for isolated Simulators. Run `scripts/setup-team-dev.sh` once to verify and merge the personal pair without deleting the agent pair. Use `scripts/mobile-dev-launch.sh --check-auth-contract --auth-profile personal` or `--auth-profile agent` for a mutation-free preflight. Never substitute one profile when the requested profile is incomplete.

## Regression test commits

Two commits, so CI proves the test catches the bug: commit 1 adds the failing test only (CI red), commit 2 adds the fix (CI green). This is visible in the PR Commits tab.

## First pass, then dogfood

A first pass ends when the change is implemented, the tagged build succeeded on the pushed HEAD, focused tests ran, and the PR is open (for `web/` PRs, also the live Vercel preview URL). Then hand off to the user. Do not sit in the main conversation watching CI or running speculative review passes after that point.

Do not launch a background review agent (`$autoreview`, `codex review`, `claude review`, or a judge loop) by default. Second-model review is explicit user opt-in in the current conversation; an implementation request, open PR, CI failure, closeout, or handoff is not that opt-in. Let required GitHub checks and the automatic review bots run asynchronously, then return to address only concrete check failures and actionable findings before merge.

The main agent owns dogfood, approval, mergeability, and every pushed fix. Merging app/runtime/UI changes requires the user's explicit approval after dogfood; if a fix changes runtime behavior mid-dogfood, rebuild the tag and say so in the handoff, since the earlier verdict covers only the build the user tested.

<!-- SUPERMUX:begin no-handoff-notify -->
**Do not send `cmux notify` at handoff or closeout.** Upstream instructs agents to notify at
these points so the user can leave and return. In this fork that is pure duplication: the agent
harness already notifies the user when a response completes, so a `cmux notify` fires a second
alert for the same event — and at handoff the user is, by construction, about to read the summary
anyway. Put the handoff information (was / now / the concrete check / the PR URL) in the final
response instead; that is the notification.

This does not ban the CLI. `cmux notify` remains correct when the user explicitly asks to be
pinged, when a skill or script sends one as part of its own job (the iPhone install queue does
this), or when testing the notification path itself.
<!-- SUPERMUX:end no-handoff-notify -->


## Pitfalls

Each of these has full detail in the skill named in parentheses.

- **Typing-latency-sensitive paths** (`cmux-debugging`): `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`, `TabItemView` in `ContentView.swift`, and `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift` run on every keystroke. Read the skill before touching them.
- **SwiftUI list boundaries** (`cmux-debugging`): no view below a `LazyVStack`/`LazyHStack`/`List`/`ForEach` boundary may hold an observable store reference, and no function called from `body` may write state. Violating either reintroduces the 100% CPU spin loop from https://github.com/manaflow-ai/cmux/issues/2586. Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **Do not add an app-level display link or manual `ghostty_surface_draw` loop.** Rely on Ghostty wakeups and its renderer, or typing lags.
- **Terminal find layering** (`cmux-debugging`): `SurfaceSearchOverlay` mounts from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), never from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- **Submodule safety** (`cmux-ghostty`): push the submodule commit to its remote `main` before committing the pointer in the parent repo. Never commit on a detached HEAD. Verify with `git merge-base --is-ancestor HEAD origin/main`.
- **Localize every user-facing string** (`cmux-localization`): `String(localized:)` with keys in `Resources/Localizable.xcstrings`, plus every web message catalog (`web/messages/en.json`, `web/messages/ja.json`). A localization audit is required for any UI, Settings, menu, schema, docs, or help-text change, and the handoff must state what was audited.
- **Shortcut policy** (`cmux-keyboard-shortcuts`): every new cmux-owned shortcut goes in `KeyboardShortcutSettings`, is editable in Settings, is supported in `~/.config/cmux/cmux.json`, and is documented.
- **Test wiring** (`cmux-testing`): a `.swift` file in `cmuxTests/` without a `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently skipped, and both `xcodebuild test` and bot reviews pass with "Executed 0 tests". `workflow-guard-tests` runs `./scripts/lint-pbxproj-test-wiring.sh` to catch it.
- **SPM package groups** (`cmux-architecture`): packages live under `Packages/{Shared,iOS,macOS}/<pkg>` and the workspace mirrors that folder shape. To move one, `git mv` the directory then `python3 scripts/check-workspace-package-groups.py --write`. Never hand-edit workspace group membership.
- **Do not gitignore cmux-owned `Package.resolved`.** SwiftPM resolution changes must show in PR diffs; package-local lockfiles are not replaced by the root one. `python3 scripts/check-package-resolved-policy.py` fails on drift.
- **"Feature flag" means a remote PostHog runtime flag.** Implement through `CmuxFeatureFlags` with a PostHog key, explicit unavailable fallback, registry metadata, live update behavior, and focused tests. A local override may support dogfood but must not be the production control plane.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change between macOS major versions.** `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 (https://github.com/manaflow-ai/cmux/issues/4529); CI and maintainer machines were all on the fixed side while every reporter was on the broken side. Test on the reporter's macOS before declaring a repro disproven. AWS M4 Pro builders (`aws-m4pro-1..6`) run macOS 15.7.4.

## Shared behavior policy

When a behavior is exposed through multiple entrypoints (shortcut, command palette, context menu, CLI, settings, debug menu), implement one shared action path and verify every entrypoint. Do not patch one surface and leave the others with duplicated logic.

For optimistic UI or CLI updates, keep one mutation path, record pending state with a request id or previous snapshot, reconcile from the authoritative result, and roll back explicitly on failure. Do not let each entrypoint keep its own optimistic copy.

When a user says tests missed a bug, add behavior-level coverage around the exact repro path before claiming the fix is complete.

## Skills

Detailed contributor rules live in `skills/`. Use the task-specific skill before changing that area.

- `cmux-dev-workflow`: setup, tagged reloads, Xcode project normalization, sidebar extension tagging, build isolation.
- `cmux-architecture`: package boundaries, file/API discipline, testability, Swift concurrency.
- `cmux-backend`: backend TypeScript, Effect, Cloud VM control plane, provider secrets, Postgres and migrations.
- `cmux-billing`: Stripe checkout, entitlements, webhooks, pricing dev stack, live provisioning.
- `cmux-debugging`: debug event log, Debug menu, runtime pitfalls, typing-sensitive paths, SwiftUI list boundaries.
- `cmux-localization`: user-facing strings, localization files, shortcut text, localization audit.
- `cmux-testing`: regression policy, Swift Testing, test quality, test wiring, local vs CI validation.
- `cmux-socket-policy`: socket command threading and focus preservation.
- `cmux-shared-behavior`: shared action paths for multi-entrypoint behavior and optimistic updates.
- `cmux-ghostty`: Ghostty submodule and GhosttyKit workflow.
- `cmux-release`: release, version bump, changelog, pretag guard, release assets.
- Blacksmith Testbox (remote Linux builds for cmux-tui): warm your own box before any cmux-tui Rust or Zig
  build, and never compile cmux-tui on the Mac. The skill lives in cmuxterm-hq at
  `skills/infra/blacksmith-testbox/SKILL.md`; the workflows, `scripts/blacksmith-*.sh`, and the
  `tests/test_testbox_*` guards stay here. Quickest path: `./scripts/blacksmith-testbox-demo.sh`.

<!-- SUPERMUX:begin claude-md-pointer -->
## Supermux fork

This checkout is **supermux**, a fork of cmux. Before making any change, read `SUPERMUX.md`
(fork rules, feature scope, upstream-merge playbook) and `SUPERMUX-TOUCHPOINTS.md` (registry of
modified upstream files). Supermux code lives in `Packages/SupermuxKit/` and `Sources/Supermux/`;
keep edits to upstream files inside `SUPERMUX:begin/end` fences and registered in the manifest.
<!-- SUPERMUX:end claude-md-pointer -->
