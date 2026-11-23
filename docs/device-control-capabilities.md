# Apple TV device control: capability table (gaulatti/atlantide#26)

The same Mattone routes as the Android TV table in gaulatti/pioggia#26. This table is written against the device-credential contract on gaulatti/mattone#23, not against its
open PR. Each row says what the client can call **today** (the device's `X-Device-ID` header, no
credential) and what the contract changes. Where mattone#23 lands, the device sends its credential
as a bearer on the same routes. Until then the client uses what exists, and a row that needs a user
session is marked as such. Read-only research against Mattone `main` (2026-11-23).

## Legend

- **Device today**: the route the client may call with only `X-Device-ID` (public routes).
- **User session today**: the route is guarded by a signed-in user, so a TV cannot call it yet.
- **After mattone#23**: the route accepts the device's credential, subject to the per-device grant
  (default: the device may manage only itself).

## Capabilities

| # | Web action (`frontend/app/routes/`) | Available on this client today | Endpoint used | Device today | After mattone#23 |
|---|---|---|---|---|---|
| 1 | Switch single and quad layout (`devices.tsx`) | no | `POST /devices/:id/quad/enable`, `POST /devices/:id/quad/disable` | user session | credential, own device |
| 2 | Choose each quadrant's channel (`channels.tsx`) | no | `POST /devices/:id/quad/play` | user session | credential, own device |
| 3 | Emergency mode on and off (`devices.tsx`) | no | `POST /devices/:id/emergency/enable`, `POST /devices/:id/emergency/disable` | user session | credential, own device |
| 4 | Emergency slot and emergency audio (`devices.tsx`) | no | `POST /devices/:id/emergency/play`, `POST /devices/:id/emergency/focus-audio/:quadrant` | user session | credential, own device |
| 5 | Emergency block on a quadrant | yes, but unauthenticated: trusts `X-Device-ID` alone | `POST /devices/emergency/block/:quadrant` | device today (hardening: mattone#23) | credential required |
| 6 | Browse channel groups (`groups.tsx`) | yes | `GET /channel-groups/for-device`, `GET /channel-groups/for-device/summaries`, `GET /channel-groups/for-device/:groupId/channels` | device today | unchanged (read) |
| 7 | Add a channel to a group (`groups.tsx`) | no | `POST /channel-groups/:id/channels/:channelId` | user session | credential, own device's groups |
| 8 | Remove a channel from a group | no | `DELETE /channel-groups/:id/channels/:channelId` | user session | credential, own device's groups |
| 9 | Create, rename and delete groups (`groups.tsx`) | no | `POST /channel-groups`, `PATCH /channel-groups/:id`, `DELETE /channel-groups/:id` | user session | credential, own device's groups |
| 10 | Play and stop per device (`home.tsx`) | partly: single stop is public (`POST /devices/single/stop`, trusts the header) | `POST /devices/:id/play`, `POST /devices/:id/stop`, `POST /devices/single/stop` | user session (play, stop); device today (single stop) | credential required |
| 11 | Stop one quadrant | unauthenticated: `POST /devices/:id/quad/stop/:quadrant` is public | `POST /devices/:id/quad/stop/:quadrant` | device today (hardening: mattone#23) | credential required |
| 12 | Add channels to the emergency pool (`channels.tsx`) | not located in the device controller on main | none found in `devices.controller.ts` | not available | to decide with mattone |
| 13 | Import channels from playlists (`import.tsx`) | no | not device-facing | out of scope (web only) | out of scope |
| 14 | Device registration and whoami | yes | `GET /devices/whoami` (public, `X-Device-ID`) | device today | unchanged |
| 15 | Channel playback (stream URL) | yes, by ticket | `GET /channels/playback/:ticket` (public) | device today | unchanged |

## What this client can do now

Rows 6, 14 and 15 work today: the client can browse groups and channels and resolve playback. Row 11,
and the single-stop of row 10, work today but are unauthenticated, so they must not be relied on
(mattone#23 is the fix). Rows 1 to 4, 7 to 9 and the play and stop of row 10 need a user session
today, so the client cannot offer them until mattone#23 lands with the device credential.

## Gaps to raise on mattone

- Row 12 (emergency pool): no device-facing route found on main. Mattone needs to say which route it
  uses before the client can offer it.
- Rows 1 to 4, 7 to 10 need a route the device credential may call. The contract says the owner grants
  this per device, so the default for a new device is "manage only itself".

## Out of scope

The other TV client (its own ticket), the phone app, and any change to the web console.
