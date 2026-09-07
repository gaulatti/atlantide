# Most Viewed tvOS verification

These screenshots were captured on the named Apple TV 4K (3rd generation)
tvOS 26.5 simulator against an isolated Mattone Compose stack. Atlantide used
the DEBUG-only `CELESTI_API_BASE_URL` override; the Release build remains fixed
to the production API.

| Evidence | Verified behavior |
| --- | --- |
| [`threshold-300.jpg`](threshold-300.jpg) | Five accepted 60-second segments leave the operator at exactly 300 seconds with only the existing source group. |
| [`threshold-301.jpg`](threshold-301.jpg) | One additional accepted second makes Most viewed appear first with the ranking icon. |
| [`channel-directory.jpg`](channel-directory.jpg) | The Channels directory presents the smart group first without changing the existing group cards. |
| [`server-ranking.jpg`](server-ranking.jpg) | The guide preserves Mattone's ordering; Rank 002 becomes first after Rank 001 is deleted. |
| [`pagination-page-2.jpg`](pagination-page-2.jpg) | Approaching the end of the first 100 rows fetches the remaining page and grows the guide to 103 channels. |
| [`cross-owner-isolation.jpg`](cross-owner-isolation.jpg) | The viewer identity still sees only its own source group while the operator has eligible history. |
| [`focus-return.jpg`](focus-return.jpg) | Leaving the guide/player returns focus to the originating Most viewed card. |
| [`sabella-catalog.jpg`](sabella-catalog.jpg) | The landed Sabella tvOS catalog builds, installs, launches, and renders on the same simulator. |

