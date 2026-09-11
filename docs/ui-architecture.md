# UI architecture

Atlantide owns Celesti device state, commands, telemetry, API mapping, and the
operational controllers for remote single-stream, quad, and emergency modes. It
does not own a parallel visual or remote-interaction system. Sabella owns both
presentation and decoder selection for authenticated live-channel playback.

All tvOS presentation is composed from the remote Sabella Swift package pinned
to exact revision `39093d503a6f5950c504855105cb7c3b6ab8c6f1`. No sibling checkout
or moving branch participates in clean, CI, or internal builds. This includes
typography, palette, brand assets, ambient and panel surfaces, registration and
standby, loading and failure states, radio
now-playing, callsign, DVR, quad layout, broadcast cells, test patterns,
emergency layout and header, carousel state, marquee, and AVPlayer rendering.
The authenticated browser is `SabellaTVChannelHome`; it owns the pinned Sabella
navigation header, the editorial Home surface, and the complete multi-row
Channels directory. Atlantide persists the current browse page and focused
group, so leaving `SabellaTVLivePlayer` restores the exact group tile and grid
row rather than resetting to the first item. Linear playback remains
`SabellaTVLivePlayer`; remote single-stream playback is
`SabellaTVSinglePlayback`. Those components own focus, guide transitions, and
remote gestures. `SabellaTVLivePlayer` also routes raw MPEG-TS, DASH, and RTMP
through Sabella's pinned KSPlayer/FFmpeg path, while HLS remains on AVPlayer;
Atlantide supplies the authoritative stream URL without substituting a player.

Sabella also owns the header focus route, user/settings button, settings action
presentation, focus geometry, and live status badge. Atlantide supplies only
the registered device identity and real product actions such as refreshing the
channel library.

The user surface displays the nullable nickname returned by Celesti's device
identity endpoint. An absent nickname is rendered as an explicit unavailable
state rather than a fabricated display name.

The device catalog loads Mattone's lightweight summaries for curated
collections, imported M3U categories, and additive smart groups. Atlantide
preserves the response order exactly. When Mattone includes
`smart:most-viewed`, its first position makes it the first non-empty Featured
group on Home and the same summary appears once in Sabella's complete Channels
directory. The smart kind maps to the distinct `chart.bar.fill` ranking icon;
collection and source icon mappings remain unchanged.

Most Viewed eligibility and ranking are server-owned. Mattone omits the summary
until an owner has a current channel with more than 300 cumulative active
seconds, so Atlantide has no threshold, local ranking, placeholder, or parallel
cache. Selecting the summary uses the generic group endpoint. Channels are
fetched in pages only after a viewer opens a group, each page remains in
Mattone's order, and the Sabella guide requests subsequent pages as focus
reaches the end of the loaded lineup. Atlantide must not download the full
library at Home.

Each channel page and remote playback command carries Mattone's authoritative
`television`, `radio`, or `automatic` medium. Atlantide maps it directly to
Sabella: radio opts into audio-first now-playing and background audio,
television remains video-first and suspends in the background, and only
automatic may use ready-media detection. Names, categories, logos, file
extensions, and URLs never determine the medium.

Leaving on-device group playback first waits for queued viewing events, converts
any automatic retry loop into one bounded delivery attempt, and serializes that
attempt with the durable outbox. A retryable failure remains persisted for the
normal background schedule instead of delaying the browser through its 1, 2,
4, 8, 16, or 30-second backoff. Atlantide then refreshes summaries without
replacing the restored browser with a loading screen. The browse page and
focused group ID remain stable when the group still exists, allowing a newly
eligible or re-ranked Most Viewed group to appear without relaunching. Manual
refresh and retry continue to expose the established loading and failure
states; a removed group clears a now-invalid focus ID.

Atlantide view files are intentionally thin adapters. They translate Celesti
presentation state into Sabella component inputs and attach product-specific
remote actions. New visual primitives must be added to Sabella with a catalog
fixture before Atlantide consumes them; do not add local fonts, colors, view
modifiers, component styling, or brand artwork here.

## Local API verification

Release builds always use `https://api.celesti.gaulatti.com`. Debug builds may
set `CELESTI_API_BASE_URL` to an absolute HTTP(S) base such as
`http://localhost:3000` so a named tvOS simulator can exercise Mattone's root
Compose stack. Invalid, credential-bearing, query-bearing, or fragment-bearing
overrides fail startup instead of falling back. The override is compiled out of
Release builds and changes the shared base for registration, channel browsing,
viewing delivery, telemetry, SSE, and device actions together.

## Channel viewing history

`ChannelViewingHistoryController` is the one attribution boundary for eligible
single-channel playback. The on-device browser passes Sabella's semantic
`SabellaTVPlaybackActivity` callback into it. The legacy single-player
controller reports the same product states only when a remote command includes
an authoritative channel UUID. A per-request generation guard prevents an older
asynchronous stream resolution from replacing newer media and attributing it to
the newer channel. Demo, quad, emergency, guide focus, and preview paths never
enter the controller.

Only engine-confirmed advancing media in an active application counts. Starting,
buffering, pause, app inactivity or background, recovery delay, failure, stop,
and channel changes close the current interval immediately. Foreground radio can
therefore count, while background radio cannot. A source switch claims the
tracker before the new stream can become active, and every late callback from
the replaced source is ignored. The accumulator uses monotonic time for duration;
wall time only anchors the API timestamps.

While playback remains active, a task checkpoints no later than every 60
seconds. Each successful checkpoint first atomically persists segments of at
most 60 seconds to `DurableChannelViewingOutbox`; a stopping transition flushes
the whole-second remainder and discards only sub-second residue. The production
outbox is stored as versioned data under the app-private
`celesti.channel-viewing-outbox` user-defaults key because tvOS denies ordinary
file creation in its app-data Documents and Application Support directories. It
uses schema version `1`, a 1,000-segment bound, verified preference writes,
and stable client-generated `segmentId` values across retries and relaunches.
Corrupt or future schemas fail closed instead of being overwritten.

`MattoneChannelViewingTransport` posts the exact landed DTO to
`https://api.celesti.gaulatti.com/channel-viewing/segments` with the registered
`X-Device-ID`. The outbox starts draining after device registration, when the
network becomes available, on app activation, and after enqueue. `recorded` and
`duplicate` are terminal success. Network errors, HTTP 408/425/429, and 5xx
responses retain the segment and retry with bounded 1, 2, 4, 8, 16, then
30-second delays. Other HTTP rejections remain durable and are skipped so one
foreign or invalid channel cannot block unrelated segments.

Viewing delivery is separate from playback reliability telemetry. Protected
unified logs expose only bounded results (`recorded`, `duplicate`, `retry`,
`terminal_rejection`, or persistence failure) and retry timing. They never log
device, channel, segment, URL, timestamp, or payload values. Mattone owns the
server-side viewing counter and database aggregate.

Signed Release creation, physical-device installation, production smoke,
rollback, and the destructive uninstall boundary are documented in
[`internal-distribution.md`](internal-distribution.md).
