# Atlantide review contract

Atlantide is the tvOS Celesti application: it owns Celesti device state,
commands, telemetry, API mapping and the operational controllers for remote
single-stream, quad and emergency playback. Presentation and decoder selection
belong to the pinned Sabella Swift package; Atlantide has no parallel visual or
remote-interaction system. Internal builds are signed Release builds for
specifically named, paired Apple TVs and are not App Store artifacts.

Preserve the ownership boundary with Sabella (exact pinned revision, no sibling
checkout or moving branch), the resilience and playback policies, the
credential-free telemetry, and the internal-distribution rules. Bug fixes,
meaningful tests, accessibility, documentation and dependency maintenance serve
this existing app without a new product decision. A new playback mode, a new
telemetry field or a change to the Sabella pin or the internal-distribution
path needs documentation or a linked requirement that establishes its need and
limits. Building or distributing signed internal builds stays a separate,
explicitly authorized action.

Assess purpose and evidence rather than the number of changed files or lines.
Ask gaulatti for a second opinion for a product-direction or authority decision.
Ordinary implementation uncertainty and repairable bugs belong to automated
investigation, not routine human code review. Changes to review controls (this
contract, `.github/clouseau.json`, the CI workflow, the local recipe) require
explicit owner confirmation.

Every material capability and mechanism must independently score at least 80
for fit, need and proportionality under Clouseau's shared protocol. A causal
technical finding at or above 70 blocks; unrelated features or good scores
cannot average away a defect. Integrity and review-completeness gates remain
independent.

Tests must assert actual behaviour. Reject fabricated coverage, disabled tests,
coverage pragmas or exclusions, swallowed errors and unconditional assertions.
The source and dependency contract, `swift test`, the tvOS simulator build and
the unsigned Release build with its inspection remain mandatory. The shared
coverage gate cannot measure Swift: the LLVM export of SwiftPM carries no branch
regions, and the gate requires measured branches. Local line coverage of the
tested resilience sources is recorded honestly for review, the policy selects
`manual` merge mode, and the owner merges every pull request.
