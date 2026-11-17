#!/usr/bin/env bash
set -euo pipefail

# Injects temporary faults into an isolated copy of the repository and verifies
# that the corresponding regression assertions FAIL (never modifies the working tree).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUITE="${1:-pr1}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sccache-mutation-XXXXXX")"
SILO_COMPOSE="$REPO_ROOT/tests/integration/docker-compose.yml"
SILO_STARTED=0
cleanup() {
    if [ "$SILO_STARTED" -eq 1 ]; then
        docker compose -f "$SILO_COMPOSE" --profile s3 down -v >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "Preparing isolated mutation workspace at $WORK (suite=$SUITE)..."
rsync -a --exclude '/target' --exclude '/.git' "$REPO_ROOT/" "$WORK/repo/"
mkdir -p "$WORK/orig"
for rel in src/compiler/rust.rs src/compiler/compiler.rs src/util.rs src/cache/disk.rs src/cache/cache.rs; do
    mkdir -p "$WORK/orig/$(dirname "$rel")"
    cp -a "$WORK/repo/$rel" "$WORK/orig/$rel"
done

restore_files() {
    for rel in src/compiler/rust.rs src/compiler/compiler.rs src/util.rs src/cache/disk.rs src/cache/cache.rs; do
        cp -a "$WORK/orig/$rel" "$WORK/repo/$rel"
    done
}

# Warm baseline build in $WORK/repo so subsequent single-file mutations compile incrementally.
(
    cd "$WORK/repo"
    export CARGO_INCREMENTAL=0
    unset RUSTC_WRAPPER || true
    if [ "$SUITE" = "pr1" ] || [ "$SUITE" = "all" ]; then
        cargo test --locked --no-run --test rust_correctness >/dev/null
    fi
    if [ "$SUITE" = "pr2" ] || [ "$SUITE" = "pr3" ] || [ "$SUITE" = "all" ]; then
        cargo build --locked --bin sccache >/dev/null
    fi
)

run_mutation() {
    local id="$1"
    local desc="$2"
    local patch_py="$3"
    local test_cmd="$4"
    local expected_marker="${5:-Running tests/}"

    echo ""
    echo "============================================================"
    echo "MUTATION [$id]: $desc"
    echo "============================================================"
    restore_files

    python3 - "$WORK/repo" "$patch_py" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
code = sys.argv[2]
exec(code, {"root": root})
PY

    set +e
    (
        cd "$WORK/repo"
        export CARGO_INCREMENTAL=0
        unset RUSTC_WRAPPER || true
        eval "$test_cmd"
    ) > "$WORK/mut_${id}.log" 2>&1
    local rc=$?
    set -e

    restore_files

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: Mutation [$id] ($desc) PASSED unexpectedly — regression test did not catch the bug!"
        tail -40 "$WORK/mut_${id}.log"
        exit 1
    elif ! grep -q "$expected_marker" "$WORK/mut_${id}.log"; then
        echo "FAIL: Mutation [$id] ($desc) failed before reaching test assertions (marker '$expected_marker' missing)!"
        tail -40 "$WORK/mut_${id}.log"
        exit 1
    else
        echo "PASS: Mutation [$id] was caught (exited $rc). Triggered failure excerpt:"
        grep -E "FAILED|panicked at|assertion|VERIFICATION FAILED|FALSE HIT|foreign root|marker|unresolved" "$WORK/mut_${id}.log" | head -10 || tail -15 "$WORK/mut_${id}.log"
    fi
}

if [ "$SUITE" = "pr1" ] || [ "$SUITE" = "all" ]; then
    run_mutation "M1_disable_cross_root_normalization" \
        "Disable SCCACHE_BASEDIRS normalization in rust.rs" \
        '
p = root / "src/compiler/rust.rs"
txt = p.read_text()
old = "let basedirs = (!basedirs.is_empty()).then_some(basedirs);"
assert old in txt
p.write_text(txt.replace(old, "let basedirs: Option<&[Vec<u8>]> = None;", 1))
' \
        "cargo test --locked --test rust_correctness test_cross_root_safe_reuse_and_manifest_dir_isolation"

    run_mutation "M2a_normalize_env_deps_with_basedirs" \
        "Normalize rustc env-deps with basedirs (causes CARGO_MANIFEST_DIR false hit)" \
        '
p = root / "src/compiler/rust.rs"
txt = p.read_text()
old = "hash_rust_value(&mut m, val, None);"
assert txt.count(old) == 1
p.write_text(txt.replace(old, "hash_rust_value(&mut m, val, basedirs);", 1))
' \
        "cargo test --locked --test rust_correctness test_cross_root_safe_reuse_and_manifest_dir_isolation"

    run_mutation "M2b_conflate_option_env_unset_and_empty" \
        "Conflate option_env! unset (None) and empty string (Some(\"\"))" \
        '
p = root / "src/compiler/rust.rs"
txt = p.read_text()
old = "None => env_deps.push((env_dep.into(), None)),"
assert old in txt
p.write_text(txt.replace(old, "None => env_deps.push((env_dep.into(), Some(OsString::new()))),", 1))
' \
        "cargo test --locked --test rust_correctness test_env_and_option_env_cache_correctness"

    run_mutation "M2c_exclude_env_deps_from_key" \
        "Exclude env-dep entries from Rust cache key" \
        '
p = root / "src/compiler/rust.rs"
txt = p.read_text()
old = "for (var, val) in env_deps.iter() {"
assert old in txt
p.write_text(txt.replace(old, "for (var, val) in std::iter::empty::<&(OsString, Option<OsString>)>() {", 1))
' \
        "cargo test --locked --test rust_correctness test_env_and_option_env_cache_correctness"

    run_mutation "M3_corrupt_depinfo_restore" \
        "Skip resolving dep-info markers back to consumer root" \
        '
p = root / "src/util.rs"
txt = p.read_text()
old = "pub fn depinfo_resolve_basedir(content: &[u8], basedir: &[u8]) -> Vec<u8> {"
assert old in txt
p.write_text(txt.replace(old, "pub fn depinfo_resolve_basedir(content: &[u8], basedir: &[u8]) -> Vec<u8> {\n    if !basedir.is_empty() { return content.to_vec(); }", 1))
' \
        "cargo test --locked --test rust_correctness test_paths_with_spaces_and_unicode_and_dep_info_integrity"

    run_mutation "M4_bypass_fail_closed_depinfo_guard" \
        "Bypass dep-info fail-closed guard on ambiguous/corrupted entries" \
        '
p = root / "src/compiler/compiler.rs"
txt = p.read_text()
old = "if !depinfo_ok {"
assert old in txt
p.write_text(txt.replace(old, "if false && !depinfo_ok {", 1))
' \
        "cargo test --locked --test rust_correctness test_dep_info_fail_closed_on_corrupted_or_ambiguous_cache_entry"
fi

if [ "$SUITE" = "pr2" ] || [ "$SUITE" = "all" ]; then
    echo "Starting Silo S3 container for PR2 mutation tests..."
    docker compose -f "$SILO_COMPOSE" --profile s3 down -v >/dev/null 2>&1 || true
    docker compose -f "$SILO_COMPOSE" --profile s3 up -d silo silo-setup >/dev/null
    SILO_STARTED=1
    attempts=0
    until curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 30 ]; then
            echo "ERROR: Silo did not become healthy for PR2 mutation suite" >&2
            exit 1
        fi
        sleep 1
    done
    docker wait "$(docker compose -f "$SILO_COMPOSE" ps -a -q silo-setup)" >/dev/null 2>&1 || true

    run_mutation "M4_disable_l0_hit" \
        "Disable Disk L0 cache reads in src/cache/disk.rs" \
        '
p = root / "src/cache/disk.rs"
txt = p.read_text()
old_get = "trace!(\"DiskCache::get({})\", key);"
old_raw = "trace!(\"DiskCache::get_raw({})\", key);"
assert old_get in txt and old_raw in txt
txt = txt.replace(old_get, "if !key.is_empty() { return Ok(Cache::Miss); }\n        " + old_get, 1)
txt = txt.replace(old_raw, "if !key.is_empty() { return Ok(None); }\n        " + old_raw, 1)
p.write_text(txt)
' \
        "cargo build --locked --bin sccache && SCCACHE_BIN=\"\$PWD/target/debug/sccache\" SCENARIOS=core SKIP_SILO_SETUP=1 KEEP_SILO=1 REPORT_DIR=\"$WORK/report-m4\" bash tests/integration/scripts/test-s3-multilevel-regression.sh" \
        "STATS_VERIFY"

    run_mutation "M5_disable_s3_l1_hit" \
        "Disable S3 L1 reads in RemoteStorage::get_with_raw" \
        '
p = root / "src/cache/cache.rs"
txt = p.read_text()
old = "async fn get_with_raw(&self, key: &str) -> Result<(Cache, Option<Bytes>)> {\n        match self.operator.read(&normalize_key(key)).await {"
assert txt.count(old) == 1
new = "async fn get_with_raw(&self, key: &str) -> Result<(Cache, Option<Bytes>)> {\n        if self.operator.info().scheme() == \"s3\" { return Ok((Cache::Miss, None)); }\n        match self.operator.read(&normalize_key(key)).await {"
p.write_text(txt.replace(old, new, 1))
' \
        "cargo build --locked --bin sccache && SCCACHE_BIN=\"\$PWD/target/debug/sccache\" SCENARIOS=core SKIP_SILO_SETUP=1 KEEP_SILO=1 REPORT_DIR=\"$WORK/report-m5\" bash tests/integration/scripts/test-s3-multilevel-regression.sh" \
        "STATS_VERIFY"
fi

echo ""
echo "All mutation checks in suite '$SUITE' succeeded (every injected bug was caught)!"
