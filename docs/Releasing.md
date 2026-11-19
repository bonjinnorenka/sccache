# Fork Release Process

This fork publishes a single Ubuntu Linux x86_64 musl binary as a GitHub
Release. It does not publish this fork's package to crates.io. Do not use
`cargo-release` for this repository.

## Version and release tags

`Cargo.toml` is the source of truth for this fork's package version. When it
changes, update the root package entry in `Cargo.lock` as well. Use a Git tag
that is exactly `v` followed by the package version:

- An upstream version without fork changes, for example `0.19.0` tagged as
  `v0.19.0`.
- A fork-specific fix release, for example `0.19.0-fork.1` tagged as
  `v0.19.0-fork.1`. The fork revision is a positive integer (`N >= 1`).

When moving to a newer upstream version, use that version as the new base and
start the fork revision again at `1` (for example, `0.20.0-fork.1`).

The workflow accepts only `MAJOR.MINOR.PATCH` and
`MAJOR.MINOR.PATCH-fork.N`, and rejects tags that do not exactly match the
package version or that point to a different commit. Existing experimental
tags and Releases are left untouched.

## Release gate

Pushing an accepted `v*` tag starts the normal CI and Release Gate. Publication
waits for Rust validation, Disk/S3 regression, GHAC Seed and Verify, Rust beta
compatibility, and the x86_64 musl smoke test. The smoke test performs a Rust
build through the release binary, packages the verified binary, creates a
SHA-256 file, and checks it. Only artifacts that pass the Release Gate are
published. The publication job downloads that same-run artifact and checks the
archive checksum again before publishing it.

The job verifies that the tag resolves to the workflow's commit and refuses
to publish if a GitHub Release already exists for the tag. It never replaces
an existing Release. Pull requests run the smoke test and package check but
do not publish. A PR run is not a test of the tag publication path, so the
first real tag publication remains a separate operational event.

GitHub requires the workflow file to be present on the default branch before
`workflow_dispatch` is available. After this workflow is integrated into
`main`, maintainers can use manual dispatch for non-release checks. Release
publication remains tag-triggered.
