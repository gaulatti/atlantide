# UI architecture

Atlantide owns Celesti device state, commands, stream resolution, playback
controllers, telemetry, and API mapping. It does not own a parallel visual or
remote-interaction system.

All tvOS presentation is composed from the local Sabella Swift package at
`../../sabella`. This includes typography, palette, brand assets, ambient and
panel surfaces, registration and standby, loading and failure states, radio
now-playing, callsign, DVR, quad layout, broadcast cells, test patterns,
emergency layout and header, carousel state, marquee, and AVPlayer rendering.
The authenticated home is `SabellaTVChannelHome`; linear playback is
`SabellaTVLivePlayer`; remote single-stream playback is
`SabellaTVSinglePlayback`. Those components own focus, guide transitions, and
remote gestures.

The device catalog loads lightweight summaries for both curated collections and
imported M3U categories. Channels are fetched in pages only after a viewer opens
a group, and the Sabella guide requests subsequent pages as focus reaches the
end of the loaded lineup. Atlantide must not download the full library at home.

Atlantide view files are intentionally thin adapters. They translate Celesti
presentation state into Sabella component inputs and attach product-specific
remote actions. New visual primitives must be added to Sabella with a catalog
fixture before Atlantide consumes them; do not add local fonts, colors, view
modifiers, component styling, or brand artwork here.
