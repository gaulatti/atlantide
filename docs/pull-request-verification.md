# Pull request verification

Local agent review uses the shared `clouseau` skill with the developer's
authenticated coding harness and the `.clouseau-local.json` recipe; it needs no
CI provider keys. `AGENTS.md` owns the rule: run it against the final committed
change before opening a PR, repair findings, and publish the passing signed
receipt in the initial ready PR body. Never push directly to `main`.

Every PR runs:

- the source and dependency contract and the resilience tests (`swift test`) on `macos-26` with Xcode 26.6,
- the locked Sabella package resolution, the tvOS simulator build, and the unsigned Release build with `scripts/verify-internal-app.sh`,
- the workflow-contract tests in `.github/tests`.

The shared coverage gate does not support Swift: SwiftPM's LLVM export has no
branch regions and the gate requires measured branches. The local recipe records
line coverage of the tested resilience sources (`scripts/clouseau-coverage.sh`)
for review. The shared policy requires a verification step named `Enforce 100% line
and branch coverage`, which here only emits a warning and enforces nothing, and
the policy selects `manual` merge mode: reviews run on every PR and the owner merges. The former `SABELLA_READ_TOKEN`
conditional is gone because Sabella is public; the tvOS builds now always run.

A PR carrying an authenticated local review stamp is verified by the pinned
Clouseau engine without AI credentials; unstamped PRs use the CI reviewer.
Reviews run on every PR and the policy selects manual merge mode, so the owner merges. Unresolved
product-direction questions go to the owner, and changes to review controls need
the owner's `/approve-intent <head SHA>` comment. See [the purpose
contract](.github/clouseau.md). The CI engine is resolved from protected
Clouseau `main` at the start of each run (see
[automatic Clouseau CI upgrades](https://github.com/gaulatti/clouseau/blob/main/docs/automatic-ci-upgrades.md)).

CI needs these repository secrets: `DEEPSEEK_API_KEY` and `TYPESAFE_API_KEY` for
the CI reviewer, and `DEPLOYMENT_TOKEN` (a token with contents write access
from an identity other than `github-actions[bot]`) for automatic repairs.
