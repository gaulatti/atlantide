# Stall watchdog: tvOS simulator evidence (gaulatti/atlantide#27)

Run on 2026-11-22 on the Apple TV 4K (3rd generation) tvOS simulator, with the
Debug build of this change plus a throwaway, uncommitted hook that starts
playback without the Celesti backend. A real Apple TV pass is a separate step.

## Source

A local live HLS source (ffmpeg `testsrc2` plus a sine tone, 2 s segments, served
by a small local HTTP server; nothing downloaded). From 20 s of stream time the
video frames are dropped from the segments, so the picture stops arriving. In
AVPlayer that stops the clock too, so every restart below is reported as
`reason=stopped_clock`. The `frozen_frames` reason (clock moving, no new frame)
is covered by the unit tests; this source did not produce it, and a picture that
keeps arriving but repeats the same image is deliberately not a stall.

## Single player

The clock stopped at 16:23:04.51 (last position advance) and the watchdog
restarted the stream at 16:23:12.76: **8.25 s**, inside N + 1 (N = 8 s).
Restarts followed at +14.3 s and +15.0 s (the 15 s backoff step; the second gap
is longer than 8 s because the restarted stream briefly played again).

```
2026-11-22 16:23:12.759274 event=stall_restart viewport=single layout=single reason=stopped_clock attempt=1 restarts=1
2026-11-22 16:23:27.055212 event=stall_restart viewport=single layout=single reason=stopped_clock attempt=2 restarts=2
2026-11-22 16:23:42.083533 event=stall_restart viewport=single layout=single reason=stopped_clock attempt=3 restarts=3
```

`single-reconnecting-badge.jpg` shows the "Reconnecting…" badge (top right,
under the transport overlay) during a restart.

## Quad: one tile restarts alone

Four tiles, three healthy sources and one (tile 2) with the video dropped.
Tile 2's clock stopped at 16:30:26.0 and it restarted at 16:30:34.27 (**8.32 s**).
Only viewport 2 ever restarted; tiles 0, 1 and 3 kept advancing (their last
samples were still `playing=true` with new frames after 100 s).

```
2026-11-22 16:30:34.273791 event=stall_restart stream=tile2 viewport=2 layout=quad reason=stopped_clock attempt=1 restarts=1
2026-11-22 16:30:48.666407 event=stall_restart stream=tile2 viewport=2 layout=quad reason=stopped_clock attempt=2 restarts=2
2026-11-22 16:31:03.824683 event=stall_restart stream=tile2 viewport=2 layout=quad reason=stopped_clock attempt=3 restarts=3
```

## Not covered

- Tiles 1 to 3 of the quad grid rendered "No stream" in screenshots even though
  their players were playing (verified from the per-player samples). That is the
  throwaway hook starting the four players without the controller republishing;
  the badge was therefore verified in the single-player view, not on a quad tile.
- The "server stops sending segments" variant was not run separately; a dried-up
  video track produced the same stopped-clock path.
- No real Apple TV, no Android TV.
