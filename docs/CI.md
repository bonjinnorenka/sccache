# Fork CI

This fork validates the environment it runs: Ubuntu 24.04 on x86_64 with
stable Rust, a Disk L0, Silo's S3-compatible L1, and GitHub Actions Cache as an
L1. The source code and Cargo features for other platforms and backends remain
available; this CI does not claim to test or release them.

## Pull request checks

The `ci` workflow runs once for pull requests. A push starts it only on `main`,
`exp-d-hardening`, or a `v*` release tag. It also runs weekly and supports
manual dispatch. The six pull request jobs are:

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
message; that status is not a GHAC pass. A maintainer must run the same commit
on a trusted branch and verify both GHAC jobs before merging. The Required
Checks ruleset must include `rust-validation`, `cache-regression`,
`ghac-verify`, `rust-beta-compatibility`, and `linux-release-smoke`.

## Extended checks and releases

The weekly run checks Rust nightly and runs all mutation tests. A manual run
can select a Rust toolchain and one of the PR1/PR2/PR3/all mutation suites, or
disable mutations. Nightly schedule failures are reported but do not block
merges. These jobs are not required checks.

A `v*` tag must point to the tested commit, and its version must match
`Cargo.toml`. Only after all required correctness, storage, GHAC, beta, and
release smoke jobs pass does the workflow publish the x86_64 musl archive and
SHA-256 file. If a GitHub Release already exists for that tag, publication
stops rather than replacing it. Pull requests run the smoke test but never
publish a release.
