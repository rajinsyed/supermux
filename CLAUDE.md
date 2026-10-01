# cmux agent notes

Keep repo-wide decisions here; procedures belong in [CONTRIBUTING.md](CONTRIBUTING.md),
[area instructions](#area-instructions) and [task skills](skills/README.md).
Read the matching skill before changing an area, then only the references needed.

**Manaflow AI team members and their agents:** read the private [cmuxterm-hq CLAUDE.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/CLAUDE.md) and [AGENTS.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/AGENTS.md) before fleet or CI work. They are the entry point for fleet builds, CI routing, agent coordination, and landing rules. Start fleet work at [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md). External contributors can ignore this block; those links return 404 for them.

## Verification and isolation

- Before committing, setup or a native build, [choose scoped verification](skills/cmux-testing/references/local-vs-ci-validation.md).
  Start with `python3 scripts/verify-local.py`; docs and portable tooling need no app build.
  Run repository commands only in a [trusted checkout](docs/contributor-verification.md#trust-boundary),
  including `verify-local.py --help`, `--list` and `--repo`. Push does not run checks for you.
- Use [CONTRIBUTING.md](CONTRIBUTING.md#getting-started) for setup. Outside cmuxterm-hq-created
  checkouts, set `CMUX_DEV_BACKEND_MODE=local` for dev builds. Follow [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md)
  for commands and cache reuse; team fleet tasks start at
  [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md).
  Never use bare `xcodebuild` or an untagged `cmux DEV.app`. Clean up only your own tags.
- A same-repo app PR gets a fleet dogfood build and link comment only while it has the
  `dev-build` label. Add it when someone will dogfood the PR, not by default; under load
  the fleet builds the newest push, and the comment says how to build a skipped commit.
- Never quit, kill, relaunch, replace or launch-profile the user's running cmux
  (`/Applications/cmux.app`, `com.cmuxterm.app`), including through a Release build or
  another bundle with that ID. Never set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`; only the
  user may. Reproduce in a tagged build and attach profiling to its PID.
- Dogfood through `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`, never `/tmp/cmux-cli`.
  Never report raw `.app` paths or `file://` URLs.
- App-linked code (`Sources/`, `CLI/`, `TunnelExtension/` and their packages) must
  remain [Swift 6.0 compatible](skills/cmux-architecture/references/swift-6-0-compatibility.md).

<!-- SUPERMUX:begin dogfood-direct-launch-link -->
## Supermux: tagged build handoff links

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

<!-- SUPERMUX:begin mac-dogfood-supermux-profile -->
## Supermux: Mac dogfood builds the user opens use `--supermux-profile`

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
`--tag` / the `~/.secrets` dogfood auto-sign-in; this checkout is not cmuxterm-hq-created, so
give them `CMUX_DEV_BACKEND_MODE=local` (a plain tagged build otherwise fails looking for the
shared dev backend). `--supermux-profile` implies `--prod-auth` and needs no backend mode.
<!-- SUPERMUX:end mac-dogfood-supermux-profile -->

## Area instructions

Read these before working in their scope; nested files may not load automatically:

- `ios/` or `Packages/iOS/`: [ios/AGENTS.md](ios/AGENTS.md).
- `web/` or any cmux Cloud database work: [web/AGENTS.md](web/AGENTS.md).
- `cmux-tui/`: [cmux-tui/AGENTS.md](cmux-tui/AGENTS.md).

<!-- SUPERMUX:begin ios-dogfood-release-build -->
## Supermux: phone dogfood uses a Release build, not `reload.sh --tag`

This overrides the "iOS builds open on the iPhone by default" section of
[ios/AGENTS.md](ios/AGENTS.md): that is upstream's workflow and does not work on this fork's phone.
`ios/scripts/reload.sh --tag` builds **Debug** with `CMUX_DEV_TAG=<tag>`, and a tagged DEV iOS build
may pair only with the same-tag Mac **DEV** build — which the user cannot sign in to. That build
installs fine and is then unusable.

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

## Contributions and publication

Before fixing a bug or adding a feature, search open upstream PRs by symptom or
issue number. Prefer landing an outside contributor's existing PR; push fixups
only when maintainer edits are allowed, and explain the changes. If using their
approach in your own PR, credit them in every such commit with `Co-authored-by`
using their commit email, link your PR from theirs and thank them. Let a human
close it; never close an outside PR without a human-written explanation.

The server directories listed in [LICENSE](LICENSE) (`web/`, `workers/ci-artifacts/`,
`workers/iroh-v2/`, `workers/presence/`, `services/iroh-relay-minter/`,
`cmux-tui/relays/cloudflare-do/`) use the Business Source License, which needs
every outside author's CLA grant. Do not merge a PR that changes those
directories while CLA Assistant is red, and do not copy an outside
contributor's work there under a `Co-authored-by` trailer unless that person
has signed the CLA. Keep code that ships in the macOS or iOS app out of those
directories.

Read [STYLE.md](STYLE.md) before drafting or revising issues, PR descriptions,
RFCs or progress updates. Fill the PR's `## Changelog` section with one
`Added`/`Changed`/`Fixed`/`Removed` line for user-visible changes, otherwise `none`.
Do not edit `CHANGELOG.md` in feature PRs; release tooling owns it.

## CI, review and merge

- Commit the failing behavioral regression before its fix; record the same
  focused command's red and green results ([testing policy](skills/cmux-testing/SKILL.md#reproduce-and-repair)).
- Check executed tests on the current SHA; green skipped jobs do not establish coverage.
  Add `full-ci` only for a user-requested or agreed broad validation plan,
  naming the extra lanes and why ([CI coverage](skills/cmux-testing/references/pr-ci-coverage.md)).
- Keep branches current locally with `scripts/merge-main.sh`; follow
  [the merge-main guide](docs/ci/merge-main.md) and never force-push over its merge.
- A first implementation pass ends with passed scoped verification and an open PR;
  do not watch CI or run speculative reviews by default.
- Before merging, use a [review subagent](skills/cmux-review/SKILL.md), correctness
  first; a second model is not a review gate. Wait for checks relevant to the
  change; disclose skipped verification on the PR. `main` is nightly: fix forward,
  do not revert.
- App/runtime/UI merges require the user’s explicit approval after dogfood **or a direct merge directive**
  (`merge`, `merge it`, `auto-merge`; not `finish`, `lgtm` or `ship it`). Follow
  [dogfood, re-dogfood and merge receipts](skills/cmux-review/SKILL.md#dogfood-and-merge).
  Notify with `cmux notify` when a socket is available.

<!-- SUPERMUX:begin no-handoff-notify -->
## Supermux: no `cmux notify` at handoff

**Do not send `cmux notify` at handoff or closeout.** This overrides the "Notify with
`cmux notify` when a socket is available" sentence in the list above, which upstream uses so the
user can leave and return. In this fork that is pure duplication: the agent
harness already notifies the user when a response completes, so a `cmux notify` fires a second
alert for the same event — and at handoff the user is, by construction, about to read the summary
anyway. Put the handoff information (was / now / the concrete check / the PR URL) in the final
response instead; that is the notification.

This does not ban the CLI. `cmux notify` remains correct when the user explicitly asks to be
pinged, when a skill or script sends one as part of its own job (the iPhone install queue does
this), or when testing the notification path itself.
<!-- SUPERMUX:end no-handoff-notify -->

## Implementation rules by task

Use these existing owners instead of duplicating their checklists here:

| Touching | Read before editing |
| --- | --- |
| Typing paths, SwiftUI list/store boundaries, rendering, find layering, UTTypes or OS-specific bugs | [cmux-debugging](skills/cmux-debugging/SKILL.md) |
| Packages, workspace groups, lockfiles or feature flags | [cmux-architecture](skills/cmux-architecture/SKILL.md) |
| Submodules or GhosttyKit | [cmux-ghostty](skills/cmux-ghostty/SKILL.md) |
| User-facing strings, docs or help | [cmux-localization](skills/cmux-localization/SKILL.md); report the localization audit |
| New cmux shortcuts | [cmux-keyboard-shortcuts](skills/cmux-keyboard-shortcuts/SKILL.md) |
| Tests or target wiring | [cmux-testing](skills/cmux-testing/SKILL.md); run `scripts/sync-test-wiring` after adding, renaming or deleting a `cmuxTests/` file |
| Multiple entrypoints or a bug that tests previously missed | [cmux-shared-behavior](skills/cmux-shared-behavior/SKILL.md); share action/mutation paths, verify every entrypoint, and cover the missed repro |

## Remote CLI relay

For v2 socket methods and remote CLI changes, read [relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md).
`RemoteRelayCommandPolicy` defaults to deny. Allowlist only for a needed remote
flow, scoped to the session's objects; command-bearing params stay denied on
every method. The PR must analyze local command/content
execution, access to unowned objects and local-state exposure, and include the
required policy tests and ID scoping. Unsafe local effects must be redesigned.
Never allowlist terminal spawn/respawn without live verification that it executes
on the remote host. An allowlist addition without this analysis blocks review.

<!-- SUPERMUX:begin claude-md-pointer -->
## Supermux fork

This checkout is **supermux**, a fork of cmux. Before making any change, read `SUPERMUX.md`
(fork rules, feature scope, upstream-merge playbook) and `SUPERMUX-TOUCHPOINTS.md` (registry of
modified upstream files). Supermux code lives in `Packages/SupermuxKit/` and `Sources/Supermux/`;
keep edits to upstream files inside `SUPERMUX:begin/end` fences and registered in the manifest.
<!-- SUPERMUX:end claude-md-pointer -->
