# Automated Regression Testing Framework

This document describes the automated regression suite for the `bonjinnorenka/sccache` fork, covering Rust cache soundness, cross-root build reuse, L0 Disk, L1 S3 (Silo), L1 GitHub Actions Cache (GHAC), Rust/Cargo compatibility, performance/hit-rate tracking, release gating, and mutation testing.

## 1. Required CI Checks and Architecture

The workflow [ci.yml](../.github/workflows/ci.yml) runs on `pull_request`, `push` to `main`, `push` of `v*` tags, and `workflow_dispatch`. It has no weekly schedule. It exposes five required status check names and six pull request jobs:

| Check Name | Job | Purpose | Script / Test Target |
|---|---|---|---|
| `rust-validation` | `rust-validation` | Formatting, TOML, Clippy, backend feature checks, Rust unit tests, and the Rust correctness, Cargo, and system integration suites | `cargo test --locked --lib --bins --tests`, [rust_correctness.rs](../tests/rust_correctness.rs), [sccache_cargo.rs](../tests/sccache_cargo.rs) |
| `cache-regression` | `cache-regression` | Disk L0 Cold / Warm / Cross-root / input-change, the full Silo S3 multilevel and fault-injection suite `S01..S10`, and Tokio Small/Medium performance | [test-disk-regression.sh](../tests/integration/scripts/test-disk-regression.sh), [test-s3-multilevel-regression.sh](../tests/integration/scripts/test-s3-multilevel-regression.sh), [test-performance-regression.sh](../tests/integration/scripts/test-performance-regression.sh) |
| `ghac-verify` | `ghac-seed` + `ghac-verify` | Cross-job real GHAC (`disk,gha`): the seed job populates GHAC from `slot-a` and passes only `seed-meta.json`; the verify job uses `slot-b`, a fresh L0 and target, and checks cross-root L1 hits, `small-manifest` isolation, and subsequent L0 backfill hits | [test-ghac-regression.sh](../tests/integration/scripts/test-ghac-regression.sh) |
| `rust-beta-compatibility` | `rust-beta-compatibility` | Runs the compatibility suite with beta against a stable reference, checking Cold/Warm/Cross-root, `env!`/`option_env!` unset vs empty, and compiler-version key isolation | [test-rust-compatibility.sh](../tests/integration/scripts/test-rust-compatibility.sh) |
| `linux-release-smoke` | `linux-release-smoke` | Builds the x86_64 musl release binary, runs it, compiles through it, packages a tarball, and verifies SHA-256 | [test-disk-regression.sh](../tests/integration/scripts/test-disk-regression.sh) |

`ghac-seed` is a job, not a required check; `ghac-verify` requires it to have succeeded. All JSON reports and sanitized logs are validated strictly by [verify_stats.py](../tests/integration/scripts/verify_stats.py) (missing fields or parse failures fail the run rather than defaulting to `0`) and retained for `14` days (intermediate binaries and seed metadata use `2` and `5` days).

## 2. GitHub Branch Protection / Ruleset Setup

To enforce these checks before merging into `main`:

1. Open **Settings -> Rules -> Rulesets** (or **Branch protection rules**).
2. Target the `main` branch.
3. Enable **Require status checks to pass before merging** and add these exact status checks:
   - `rust-validation`
   - `cache-regression`
   - `ghac-verify`
   - `rust-beta-compatibility`
   - `linux-release-smoke`

## 3. Security and Resource Hygiene

- **External fork PRs & GHAC**: `ghac-seed` runs only when the pull request comes from this repository, and `ghac-verify` fails explicitly instead of reporting a GHAC pass when the seed did not run. External fork PRs do not receive `actions: write` permissions or `ACTIONS_RUNTIME_TOKEN` access.
- **Namespace isolation**:
  - GHAC runs use `SCCACHE_GHA_VERSION="reg-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.sha }}"`, completely isolated from external project/production GHAC namespaces.
  - S3 regression runs talk only to the ephemeral local Silo container (`pgsty/silo` + `pgsty/mc`) with dummy `minioadmin` credentials (`AWS_EC2_METADATA_DISABLED=true`) and unique per-run `SCCACHE_S3_KEY_PREFIX` prefixes; production buckets or external S3 credentials are never used.
- **Token redaction**: `verify_stats.py sanitize-log` scrubs `ACTIONS_RUNTIME_TOKEN`, `ACTIONS_RESULTS_URL`, `ACTIONS_CACHE_URL`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `GITHUB_TOKEN`, Bearer headers, and signed URL query parameters from uploaded logs and reports.

## 4. Pinned Fixtures

- [tokio-small](../tests/fixtures/tokio-small/Cargo.toml): `small-core` (`tokio` full, `serde` derive, `serde_json`), `small-manifest` (`env!("CARGO_MANIFEST_DIR")` + unit test), and `small-app` binary, with pinned [Cargo.lock](../tests/fixtures/tokio-small/Cargo.lock).
- [tokio-medium](../tests/fixtures/tokio-medium/Cargo.toml): `medium-core` (`tokio` full, `serde` derive, `serde_json`, `reqwest` `0.12` with `rustls-tls` / `ring`, `axum` `0.8`, `tracing`, `tracing-subscriber`), `medium-manifest`, and `medium-app`, with pinned [Cargo.lock](../tests/fixtures/tokio-medium/Cargo.lock).

## 5. Mutation Testing

[scripts/run-mutation-tests.sh](../scripts/run-mutation-tests.sh) copies the repository into an isolated temporary workspace, injects faults one at a time, compiles, and verifies that the target regression suite fails on its real assertion:

```bash
bash scripts/run-mutation-tests.sh pr1   # M1, M2a, M2b, M2c
bash scripts/run-mutation-tests.sh pr2   # M4_disable_l0_hit, M5_disable_s3_l1_hit (requires Docker)
bash scripts/run-mutation-tests.sh pr3   # M6_disable_ghac_l1_hit (uses a local GHAC v1 HTTP mock)
bash scripts/run-mutation-tests.sh all   # Full M1..M6 suite
```

## 6. Cache-key behavior documented during implementation

1. **`option_env!` unset vs empty (`src/compiler/rust.rs`)**: `parse_env_dep_info`, `parse_dep_file`, `get_source_files_and_env_deps`, and `generate_hash_key` preserve `Option<OsString>` (`# env-dep:VAR` -> `None`, `# env-dep:VAR=` -> `Some("")`), preventing false hits between unset and empty `option_env!` variables. `CACHE_VERSION` is `10`.
2. **Client-side `compile_requests` accounting (`src/server.rs`)**: `SccacheService::compile_direct` (`SCCACHE_CLIENT_SIDE=1`) increments `compile_requests` so `--show-stats` reports request counts consistently across daemon and client-side modes.
3. **Rust dep-info is local**: upstream 0.19 writes Rust `.d` files from the hashing invocation and no longer caches them. The fork's previous marker/rewrite protocol is therefore not needed; cross-root correctness relies on the cache key normalization plus local generation. Cache entries must not contain `.d` members, and cross-root hits must produce `.d` files naming the consuming root.
4. **`MultiLevelStorage` stats reset on `--zero-stats`**: `Server::zero_stats` resets `ServerStats` without resetting `MultiLevelStorage`'s `AtomicLevelStats`. Scripts that assert per-leg `multi_level` hit/miss breakdowns restart the `sccache` daemon while preserving the L0 cache directory.
5. **Cross-root `# env-dep:OUT_DIR` misses**: because tracked `env-dep` values are hashed verbatim, crates whose build scripts cause `rustc` to track `OUT_DIR` (for example `proc-macro2`, `serde_core`, `serde`, `serde_json` in the `tokio-small` graph alongside `small-manifest`) miss safely across different roots (~82% cross-root hit rate on `tokio-small`, ~92% on `tokio-medium`).
