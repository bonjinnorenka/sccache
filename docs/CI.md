# Fork CI

This fork validates the environment it runs: Ubuntu 24.04 on x86_64 with
stable Rust, a Disk L0, Silo's S3-compatible L1, and GitHub Actions Cache as an
L1. The source code and Cargo features for other platforms and backends remain
available; this CI does not claim to test or release them.

## Pull request checks

The `ci` workflow runs for pull requests, pushes to `main`, `v*` tags, and
manual dispatch. It has no schedule trigger. The six pull request jobs are:

1. `rust-validation`: formatting, TOML formatting, Clippy, supported backend
   feature checks, Rust unit and integration tests, and a shared Linux binary.
2. `cache-regression`: Disk L0 Cold/Warm/Cross-root/dep-info checks, the full
   Silo S3 multilevel and fault-injection suite, and Tokio Small/Medium
   performance measurements.
3. `ghac-seed`: writes the isolated GHAC cache from one job.
4. `ghac-verify`: reads that cache from another job with a clean L0 and a
   different build root, then checks the L1 hit, backfill, and output.
5. `rust-beta-compatibility`: checks cache correctness with Rust beta and
   isolates stable and beta compiler cache keys.
6. `linux-release-smoke`: builds the x86_64 musl release binary, runs it, and
   compiles a Rust fixture through it.

The jobs share the stable debug binary where that is meaningful. Release
smoke builds and tests the separate musl artifact. The Disk and S3 harnesses
remove their own target and L0 directories between cold and warm phases.

Fork pull requests do not receive the Actions cache write credentials. In
that case `ghac-seed` is skipped and `ghac-verify` fails with an explicit
message; that status is not a GHAC pass. Directly merging an external fork PR
is unsupported. To take its changes, a maintainer reviews them, transfers the
approved changes to a trusted branch in this repository, and opens a new PR
from that branch. This does not make the original external PR's required check
pass. Do not use `pull_request_target` to run untrusted PR code with write
permissions.

The active Required Checks ruleset includes `rust-validation`,
`cache-regression`, `ghac-verify`, `rust-beta-compatibility`, and
`linux-release-smoke`. The `ghac-verify` job explicitly requires a successful
`ghac-seed` result.

## When checks run

| Event | Checks |
|---|---|
| Pull request update | Normal CI |
| Push to `main` | Normal CI |
| `v*` release tag | Normal CI, Release Gate, then publication |
| `workflow_dispatch` | Normal CI, or selected extended checks; never publishes |
| `schedule` | Not used |

GitHub requires a workflow file to exist on the default branch before it can
be started with `workflow_dispatch`. After integration into `main`, open
**Actions**, select `ci` or `extended-rust-checks`, choose a ref, and run the
workflow. The extended workflow accepts a Rust toolchain and a mutation suite
(`all`, `pr1`, `pr2`, `pr3`, or `none`). A selected nightly run fails normally
when a check fails; there is no `continue-on-error`.

## Extended checks and releases

The separate `extended-rust-checks` workflow is manual-only. Run it with
`nightly` for Rust nightly compatibility or provide an explicit Rust version.
Mutation tests run unless the selected suite is `none`. These checks are not
required for merges.

A release tag must point to the tested commit and match either
`v<package-version>` or `v<package-version>-fork.<positive-revision>` exactly.
Only after all required correctness, storage, GHAC, beta, and release smoke
jobs pass does a tag-triggered push publish the x86_64 musl archive and
SHA-256 file. Manual dispatch never runs the publication job.
The checksum is checked both after packaging and after artifact download. If a
GitHub Release already exists for that tag, publication stops rather than
replacing it. Pull requests run the smoke test but never publish a release.
