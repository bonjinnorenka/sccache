# Automated Regression Testing Framework

This document describes the automated regression suite for the `bonjinnorenka/sccache` fork (`exp-d-hardening` branch), covering Rust cache soundness, cross-root build reuse, L0 Disk, L1 S3 (Silo), L1 GitHub Actions Cache (GHAC), Rust/Cargo compatibility, performance/hit-rate tracking, release gating, and mutation testing.

## 1. Required CI Checks and Architecture

The workflow [regression.yml](../.github/workflows/regression.yml) runs on `pull_request`, `push` to `main` / `exp-d-hardening`, `workflow_dispatch`, and a weekly `schedule` (`17 3 * * 1` UTC). It exposes six required status check names:

| Check Name | Purpose | Script / Test Target |
|---|---|---|
| `sccache-rust-correctness` | Unit tests (`--lib`) + Rust cache key, `env!`/`option_env!`, `build.rs`, `OUT_DIR`, `proc-macro`, `--remap-path-prefix`, Unicode/space `.d` rewriting, fail-closed `.d` corruption handling, and concurrent multi-root requests | `cargo test --locked --lib`, [rust_correctness.rs](../tests/rust_correctness.rs) |
| `sccache-disk-regression` | Upstream + audited Cargo integration suite (`basedirs`, per-request config isolation) and standalone Disk L0 Cold / L0 Warm / Cross-root / Input-change verification | [sccache_cargo.rs](../tests/sccache_cargo.rs), [test-disk-regression.sh](../tests/integration/scripts/test-disk-regression.sh) |
| `sccache-s3-regression` | Real L0 (`disk`) + L1 (`s3` via Docker Compose Silo) multilevel suite `S01..S10` covering Cold, L0 Warm, S3 L1 Warm, Cross-root + `.d`, L0 backfill, source edits, `WriteErrorPolicy` (`ignore` / `l0` / `all`), auth failure, mid-session Silo stop, and concurrent slots | [test-s3-multilevel-regression.sh](../tests/integration/scripts/test-s3-multilevel-regression.sh), [docker-compose.yml](../tests/integration/docker-compose.yml) |
| `sccache-ghac-regression` | Cross-job real GHAC (`disk,gha`): Job A (`ghac-seed`, `slot-a`) populates GHAC and passes only `seed-meta.json`; Job B (`sccache-ghac-regression`, `slot-b`, fresh L0 & target, no `actions/cache` for target/L0) verifies cross-root L1 hits, `small-manifest` isolation, `.d` integrity, and subsequent L0 backfill hits | [test-ghac-regression.sh](../tests/integration/scripts/test-ghac-regression.sh) |
| `sccache-rust-compatibility` | Reuses a single pre-built `sccache` binary across `stable`, `beta`, and `1.91.0` (`fail-fast: false`), checking `tokio-small` Cold/Warm/Cross-root, `env!`/`option_env!`, and compiler-version cache key isolation; aggregates status alongside non-blocking `sccache-rust-compatibility-nightly` | [test-rust-compatibility.sh](../tests/integration/scripts/test-rust-compatibility.sh) |
| `sccache-performance` | Measures dependency fetch separately from compilation across `tokio-small` and `tokio-medium` (`Cold`, `L0 Warm x2`, `Silo L1 Warm`, `Cross-root L1 Warm`) and verifies hit rates and warm speedups | [test-performance-regression.sh](../tests/integration/scripts/test-performance-regression.sh) |

All JSON reports and sanitized logs are validated strictly by [verify_stats.py](../tests/integration/scripts/verify_stats.py) (missing fields or parse failures fail the run rather than defaulting to `0`) and retained for `14` days (`retention-days: 14`; intermediate binaries/seed metadata use `5` days).

## 2. GitHub Branch Protection / Ruleset Setup

To enforce these checks before merging into `exp-d-hardening` or `main`:

1. Open **Settings -> Rules -> Rulesets** (or **Branch protection rules**).
2. Target branches `exp-d-hardening` and `main`.
3. Enable **Require status checks to pass before merging** and add these exact 6 status checks:
   - `sccache-rust-correctness`
   - `sccache-disk-regression`
   - `sccache-s3-regression`
   - `sccache-ghac-regression`
   - `sccache-rust-compatibility`
   - `sccache-performance`
4. Keep `sccache-rust-compatibility-nightly` **optional** (do not add it as a required check); `continue-on-error: true` ensures upstream nightly compiler/Cargo churn does not block releases while still publishing diagnostics.

### Release Gate

In [ci.yml](../.github/workflows/ci.yml), tag builds (`refs/tags/*`) run the `regression-gate` job (`--lib`, `rust_correctness`, `sccache_cargo`, Disk regression, and Silo S3 multilevel regression) and `release` declares `needs: [ build, lint, test, regression-gate ]` so no release artifacts can be built if regression verification fails.

## 3. Security and Resource Hygiene

- **External fork PRs & GHAC**: `ghac-seed` and `sccache-ghac-regression` run only when `github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository`. External fork PRs do not receive `actions: write` permissions or `ACTIONS_RUNTIME_TOKEN` access.
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
bash scripts/run-mutation-tests.sh pr1   # M1, M2a, M2b, M2c, M3, M4_bypass_fail_closed_depinfo_guard
bash scripts/run-mutation-tests.sh pr2   # M4_disable_l0_hit, M5_disable_s3_l1_hit (requires Docker)
bash scripts/run-mutation-tests.sh pr3   # M6_disable_ghac_l1_hit (uses local GHAC v1 HTTP mock)
bash scripts/run-mutation-tests.sh all   # Full M1..M6 suite
```

## 6. Known Fork Behaviors & Findings Documented During Implementation

1. **`option_env!` unset vs empty fix (`src/compiler/rust.rs`)**: `parse_env_dep_info`, `parse_dep_file`, `get_source_files_and_env_deps`, and `generate_hash_key` were updated to preserve `Option<OsString>` (`# env-dep:VAR` -> `None` hashed with tag `0`, `# env-dep:VAR=` -> `Some("")` hashed with tag `1`), preventing false hits between unset and empty `option_env!` variables while retaining `CACHE_VERSION = b"9"`.
2. **Client-side `compile_requests` accounting fix (`src/server.rs`)**: `SccacheService::compile_direct` (`SCCACHE_CLIENT_SIDE=1`) now increments `self.stats.lock().await.compile_requests += 1` so `--show-stats` reports request counts consistently across daemon and client-side modes.
3. **Windows `.d` dep-info basedir marking (`src/util.rs`, known limitation)**: `Config::normalize_basedirs` canonicalizes Windows drive prefixes into lowercase forward-slash bytes (e.g., `c:/...`), whereas `depinfo_mark_basedir` operates on raw backslash bytes (`C:\...`) in compiler dep-info files. Path-string rewrite checks inside `.d` files are therefore scoped to `#[cfg(unix)]` in tests, while Windows builds remain protected by runtime `CARGO_MANIFEST_DIR` / `OUT_DIR` isolation and cross-root compilation tests.
4. **`MultiLevelStorage` stats reset on `--zero-stats` (`src/server.rs`)**: `Server::zero_stats` resets `ServerStats` (`rust_hits`, `rust_misses`, `compile_requests`, etc.) without resetting `MultiLevelStorage`'s `AtomicLevelStats`. Scripts that assert per-leg `multi_level` hit/miss breakdowns restart the `sccache` daemon while preserving the L0 cache directory.
5. **Cross-root `# env-dep:OUT_DIR` misses & proc-macro `--extern` reproducibility**: Because `exp-d-hardening` intentionally hashes `# env-dep:` values without `basedirs` normalization, crates whose build scripts cause `rustc` to track `OUT_DIR` (such as `proc-macro2`, `serde_core`, `serde`, `serde_json` in the `tokio-small` graph alongside `small-manifest`) miss safely across different roots (~82% cross-root hit rate on `tokio-small`, ~92% on `tokio-medium`). Additionally, uncached `proc-macro` `.dll` / `.dylib` crates on Windows MSVC and macOS embed linker metadata (COFF timestamps / PDB GUIDs / Mach-O UUIDs), causing downstream `--extern` consumers to validly miss across roots on those platforms.
6. **Cargo `beta` (`1.101`) / `nightly` (`1.102`) target layout**: Intermediate `.d` and `.rlib` files may live under `target/debug/build/<pkg>/...` rather than `target/debug/deps/`. Test helpers walk `target/debug` recursively.
