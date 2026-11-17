# Sccache Release Process

This fork publishes only an Ubuntu Linux x86_64 musl binary. The `ci` workflow
validates the tagged commit, Rust cache correctness, Disk and S3 regressions,
cross-job GHAC reuse, Rust beta compatibility, and the release binary smoke
test before creating a GitHub Release. The archive includes a SHA-256 file.
Pull requests run the smoke test but do not publish. If a release already
exists for a tag, the workflow refuses to replace it. See [Fork CI](CI.md) for
the required checks and GHAC behavior on fork pull requests.

# Producing a release

We use [`cargo-release`](https://crates.io/crates/cargo-release) to produce releases, since it encapsulates the steps of bumping the version number, creating and pushing a new tag, and releasing to [crates.io](https://crates.io/crates/sccache). You can install it with `cargo install cargo-release`, then simply run `cargo release` in an sccache checkout to do the work. Note that it supports a `--dry-run` option you can use to preview what it will run.

## Things to be aware of

1. You must have authenticated to crates.io using `cargo login` to publish the sccache create there.
2. cargo will not allow publishing a create if there are crates in the `[patch]` section in `Cargo.toml`.
