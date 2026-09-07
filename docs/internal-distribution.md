# Internal tvOS builds

Atlantide internal builds are signed Release builds for a specifically named,
paired Apple TV. They are not App Store artifacts and must not be distributed
outside the intended test device. Production behavior remains owned by the
reviewed source SHA and the production Mattone API.

## Immutable inputs

The Xcode project resolves Sabella from
`https://github.com/gaulatti/sabella.git` at exact revision
`39093d503a6f5950c504855105cb7c3b6ab8c6f1`. The committed
`Package.resolved` locks Sabella and its transitive media dependencies.
Machine-specific `workspace-state.json` files are ignored and must never be
committed. `scripts/verify-source-contract.sh` fails if the project returns to
a sibling checkout or its lock drifts.

Release binaries compile out `CELESTI_API_BASE_URL` and use only
`https://api.celesti.gaulatti.com`. Internal builds embed their exact Git SHA in
`AtlantideGitSHA`; the build helper refuses a dirty checkout or implicit
version/build number.

## Prerequisites

- Xcode 26.6 with the tvOS platform installed.
- A physical Apple TV in Developer Mode, paired and reachable from the Mac.
- An existing Apple Development identity and provisioning profile for team
  `N32N2U54JS` and bundle `com.gaulatti.celesti`.
- The exact reviewed commit checked out with no local changes.
- A previously verified signed `.app` retained locally before replacing an
  existing installation.

List candidates and record the chosen name, model, tvOS version, and Xcode
destination ID/UDID without committing serial numbers or device identifiers.
Use the `id` from `-showdestinations`; `devicectl` accepts that same UDID:

```sh
xcrun devicectl list devices
xcodebuild -project celesti.xcodeproj -scheme celesti -showdestinations
xcrun devicectl device info details --device <device-id>
xcrun devicectl device info apps --device <device-id> \
  --bundle-id com.gaulatti.celesti
```

## Build and verify

Choose version and build numbers deliberately. Keep output outside the checkout:

```sh
scripts/build-internal.sh \
  <device-id> \
  1.0.0 \
  <positive-build-number> \
  /private/tmp/atlantide-internal
```

The command resolves only the committed package graph, performs a signed Release
build for the named device, and fails unless the app has the expected bundle ID,
version, build, Git SHA, production-only API configuration, and a valid deep
signature. It reports the executable SHA-256 plus signing identity, team, and
CodeDirectory hash.

Do not add `-allowProvisioningUpdates` to an unattended run. If existing signing
material cannot produce the build, stop and obtain explicit authorization before
changing certificates, registered devices, or profiles.

## Install and launch

Installing the same bundle replaces the executable while preserving the app
container. Capture the current installed version/build and retain its signed app
first so rollback is possible.

```sh
xcrun devicectl device install app \
  --device <device-id> \
  /private/tmp/atlantide-internal/DerivedData/Build/Products/Release-appletvos/celesti.app

xcrun devicectl device process launch \
  --device <device-id> \
  --terminate-existing \
  com.gaulatti.celesti
```

Confirm the foreground app on that same physical device rather than inferring
success from a build or PID. Exercise the existing authenticated owner session,
Home and Channels focus, HLS and opaque-stream playback, guide/Menu behavior,
pause/resume, and recovery. Stop if the app asks for a new production
registration; creating one is a separate production mutation.

For viewing-history acceptance, record the start/end monotonic interval and
play continuously for more than five minutes. Exercise one offline/relaunch
cycle, then confirm the same durable segment IDs reach the owner-scoped Mattone
behavior exactly once. This writes production viewing history and therefore
requires explicit authorization; simulator/unit evidence cannot replace it.

## Rollback and removal

On a smoke failure, stop testing and reinstall the retained previous signed
`.app` with `devicectl device install app`, then relaunch and verify its recorded
version/build. Reinstallation preserves the existing container, registration,
and durable outbox.

Uninstall only with explicit approval:

```sh
xcrun devicectl device uninstall app \
  --device <device-id> \
  com.gaulatti.celesti
```

Uninstalling deletes the app container, including registration and queued
viewing segments, so it is destructive and is not the normal rollback path.
