# UI architecture

Atlantide owns Celesti device state, commands, telemetry, API mapping, and the
operational controllers for remote single-stream, quad, and emergency modes. It
does not own a parallel visual or remote-interaction system. Sabella owns both
presentation and decoder selection for authenticated live-channel playback.

All tvOS presentation is composed from the local Sabella Swift package at
`../../sabella`. This includes typography, palette, brand assets, ambient and
panel surfaces, registration and standby, loading and failure states, radio
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

The device catalog loads lightweight summaries for both curated collections and
imported M3U categories. Channels are fetched in pages only after a viewer opens
a group, and the Sabella guide requests subsequent pages as focus reaches the
end of the loaded lineup. Atlantide must not download the full library at home.

Atlantide view files are intentionally thin adapters. They translate Celesti
presentation state into Sabella component inputs and attach product-specific
remote actions. New visual primitives must be added to Sabella with a catalog
fixture before Atlantide consumes them; do not add local fonts, colors, view
modifiers, component styling, or brand artwork here.

## Channel viewing history foundation

`ActiveChannelViewingAccumulator` is a pure, unwired timing state machine for a
future live-player adapter. It counts only monotonic time spent continuously in
`playing` for one authoritative channel ID. Buffering, pause, app inactivity,
failure, stop, and channel changes close the active interval without counting
their elapsed time. Wall-clock values only anchor the segment timestamps, so a
wall-clock adjustment cannot change `activeSeconds`.

The adapter must call `checkpoint()` no later than each 60-second boundary
while playback remains active. Each successful checkpoint first atomically
persists one or more segments of at most 60 seconds to
`DurableChannelViewingOutbox`; the remaining unpersisted whole and fractional
interval is then strictly less than 60 seconds. A non-playing transition flushes
the whole-second remainder and discards only sub-second residue. If persistence
fails or the bounded outbox is full, the transition fails without advancing the
checkpoint, so the adapter must surface the failure and stop claiming that
viewing history is current.

The outbox stores a deterministic JSON document with schema version `1` and
retains the original client-generated `segmentId` across retries and relaunches.
It removes a segment only after `recorded` or `duplicate`. A retryable failure
remains eligible for delivery; a terminal rejection remains durable and visible
but is skipped by automatic delivery. Corrupt or unknown persisted schemas fail
closed instead of being overwritten. `FileChannelViewingOutboxPersistence`
uses an atomic local file write, while tests inject an in-memory store.

No player event adapter, Mattone endpoint, transport implementation, production
telemetry, or user-visible surface is wired in this foundation. The later
integration issue owns mapping real Sabella playback transitions, scheduling
the checkpoint deadline, selecting the app-support file URL, and delivering the
landed segment contract to Mattone.
