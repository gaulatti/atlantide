# UI architecture

Atlantide owns Celesti device state, commands, stream resolution, playback
controllers, telemetry, and remote-control bindings. It does not own a parallel
visual system.

All tvOS presentation is composed from the local Sabella Swift package at
`../../sabella`. This includes typography, palette, brand assets, ambient and
panel surfaces, registration and standby, loading and failure states, radio
now-playing, callsign, DVR, quad layout, broadcast cells, test patterns,
emergency layout and header, carousel state, marquee, and AVPlayer rendering.

Atlantide view files are intentionally thin adapters. They translate Celesti
presentation state into Sabella component inputs and attach product-specific
remote actions. New visual primitives must be added to Sabella with a catalog
fixture before Atlantide consumes them; do not add local fonts, colors, view
modifiers, component styling, or brand artwork here.
