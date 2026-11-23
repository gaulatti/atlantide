# Apple TV device control: capability table (gaulatti/atlantide#26)

Each row maps a web action to its endpoint and says whether this client can use it today. The
device-credential work that changes the last column is tracked outside this repository.

## Legend

- **Available today**: yes, the client can make this call with what it has now.
- **Auth**: what the call needs. "User session" means a signed-in user token. Device-credential
  changes are described in the last column of the table.

## Capabilities

| # | Web action (`frontend/app/routes/`) | Available on this client today | Endpoint used | Auth | After the device-credential change |
|---|---|---|---|---|---|
| 1 | Switch single and quad layout (`devices.tsx`) | no | `POST /devices/:id/quad/enable`, `POST /devices/:id/quad/disable` | user session | device credential required after mattone#23 |
| 2 | Choose each quadrant's channel (`channels.tsx`) | no | `POST /devices/:id/quad/play` | user session | device credential required after mattone#23 |
| 3 | Emergency mode on and off (`devices.tsx`) | no | `POST /devices/:id/emergency/enable`, `POST /devices/:id/emergency/disable` | user session | device credential required after mattone#23 |
| 4 | Emergency slot and emergency audio (`devices.tsx`) | no | `POST /devices/:id/emergency/play`, `POST /devices/:id/emergency/focus-audio/:quadrant` | user session | device credential required after mattone#23 |
| 5 | Emergency block on a quadrant | no | (not listed) | device credential required after mattone#23 | device credential required after mattone#23 |
| 6 | Browse channel groups (`groups.tsx`) | yes | `GET /channel-groups/for-device`, `GET /channel-groups/for-device/summaries`, `GET /channel-groups/for-device/:groupId/channels` | device id | unchanged |
| 7 | Add a channel to a group (`groups.tsx`) | no | `POST /channel-groups/:id/channels/:channelId` | user session | device credential required after mattone#23 |
| 8 | Remove a channel from a group | no | `DELETE /channel-groups/:id/channels/:channelId` | user session | device credential required after mattone#23 |
| 9 | Create, rename and delete groups (`groups.tsx`) | no | `POST /channel-groups`, `PATCH /channel-groups/:id`, `DELETE /channel-groups/:id` | user session | device credential required after mattone#23 |
| 10 | Play and stop per device (`home.tsx`) | no | `POST /devices/:id/play`, `POST /devices/:id/stop` | user session | device credential required after mattone#23 |
| 11 | Stop one quadrant | no | (not listed) | device credential required after mattone#23 | device credential required after mattone#23 |
| 12 | Add channels to the emergency pool (`channels.tsx`) | no | no device-facing route identified yet | to be decided with Mattone | to be decided with Mattone |
| 13 | Import channels from playlists (`import.tsx`) | no | not device-facing | out of scope (web only) | out of scope |
| 14 | Device registration and whoami | yes | `GET /devices/whoami` | device id | unchanged |
| 15 | Channel playback (stream URL) | yes | `GET /channels/playback/:ticket` | ticket | unchanged |

## What this client can do now

Rows 6, 14 and 15 work today: the client can browse groups and channels and resolve playback.
Rows 1 to 4, 7 to 10 need a user session, so this client cannot offer them until the device-credential
change lands.

## Open items

- Row 12 (emergency pool): Mattone needs to name the device-facing route before this client can offer it.
- Rows 1 to 4, 5, 7 to 11 need a credential the device may use; the default for a new device is to manage only itself.

## Out of scope

The Android TV client (its own ticket), the phone app, and any change to the web console.
