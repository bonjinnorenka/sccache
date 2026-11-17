#!/usr/bin/env bash
set -euo pipefail

# Standalone Disk L0 regression harness (Cold, L0 Warm, Cross-root, Dep-info, Source change).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VERIFY_PY="$SCRIPT_DIR/verify_stats.py"

SCCACHE_BIN="${SCCACHE_BIN:-$REPO_ROOT/target/debug/sccache}"
REPORT_DIR="${REPORT_DIR:-$REPO_ROOT/target/regression-reports/disk}"
mkdir -p "$REPORT_DIR"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sccache-disk-reg-XXXXXX")"
cleanup() {
    "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
    if [ -f "$WORK_ROOT/sccache.log" ]; then
        python3 "$VERIFY_PY" sanitize-log "$WORK_ROOT/sccache.log" "$REPORT_DIR/disk-server.log" || true
    fi
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

L0_DIR="$WORK_ROOT/l0-cache"
mkdir -p "$L0_DIR"
export SCCACHE_DIR="$L0_DIR"
export SCCACHE_SERVER_UDS="$WORK_ROOT/sccache.sock"
export SCCACHE_IDLE_TIMEOUT=0
export SCCACHE_LOG="sccache=debug"
export SCCACHE_ERROR_LOG="$WORK_ROOT/sccache.log"
export CARGO_INCREMENTAL=0

create_fixture() {
    local slot_dir="$1"
    local proj="$slot_dir/project"
    mkdir -p "$proj/safe_dep/src" "$proj/manifest_dep/src" "$proj/app/src"
    cat > "$proj/Cargo.toml" <<'TOML'
[workspace]
members = ["safe_dep", "manifest_dep", "app"]
resolver = "2"
TOML
    cat > "$proj/safe_dep/Cargo.toml" <<'TOML'
[package]
name = "safe_dep"
version = "0.1.0"
edition = "2024"
TOML
    cat > "$proj/safe_dep/src/lib.rs" <<'RS'
pub fn compute(n: u64) -> u64 {
    n * 7 + 11
}
RS
    cat > "$proj/manifest_dep/Cargo.toml" <<'TOML'
[package]
name = "manifest_dep"
version = "0.1.0"
edition = "2024"
[dependencies]
safe_dep = { path = "../safe_dep" }
TOML
    cat > "$proj/manifest_dep/src/lib.rs" <<'RS'
pub fn manifest_dir() -> &'static str {
    env!("CARGO_MANIFEST_DIR")
}
pub fn total(n: u64) -> u64 {
    safe_dep::compute(n)
}
RS
    cat > "$proj/app/Cargo.toml" <<'TOML'
[package]
name = "app"
version = "0.1.0"
edition = "2024"
[dependencies]
safe_dep = { path = "../safe_dep" }
manifest_dep = { path = "../manifest_dep" }
TOML
    cat > "$proj/app/src/main.rs" <<'RS'
fn main() {
    println!("{}|{}", manifest_dep::total(3), manifest_dep::manifest_dir());
}
RS
}

SLOT_A="$WORK_ROOT/slot-a"
SLOT_B="$WORK_ROOT/slot-b"
create_fixture "$SLOT_A"
create_fixture "$SLOT_B"

"$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
"$SCCACHE_BIN" --start-server

run_leg() {
    local leg="$1"
    local slot="$2"
    local target="$3"
    shift 3

    rm -rf "$target"
    "$SCCACHE_BIN" --zero-stats >/dev/null

    local t0 t1 elapsed
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    (
        cd "$slot/project"
        export RUSTC_WRAPPER="$SCCACHE_BIN"
        export CARGO_TARGET_DIR="$target"
        export SCCACHE_BASEDIRS="$slot"
        export RUSTFLAGS="--remap-path-prefix=$slot=/topsrc"
        cargo build --color=never >/dev/null
    )
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    elapsed="$(python3 -c "print($t1 - $t0)")"

    local stats_file="$WORK_ROOT/stats_${leg}.json"
    "$SCCACHE_BIN" --show-stats --stats-format=json > "$stats_file"
    python3 "$VERIFY_PY" verify \
        --stats-file "$stats_file" \
        --leg-name "$leg" \
        --elapsed-sec "$elapsed" \
        --output-json "$REPORT_DIR/leg_${leg}.json" \
        "$@"
}

# 1. Cold build in slot-a (safe_dep + manifest_dep = 2 misses)
run_leg "cold" "$SLOT_A" "$SLOT_A/project/target" \
    --min-compile-requests 3 \
    --exact-rust-hits 0 \
    --exact-rust-misses 2 \
    --exact-read-errors 0 \
    --exact-write-errors 0

# 2. L0 warm build in slot-a (2 hits, 0 misses)
run_leg "l0_warm" "$SLOT_A" "$SLOT_A/project/target" \
    --min-compile-requests 3 \
    --exact-rust-hits 2 \
    --exact-rust-misses 0 \
    --exact-read-errors 0 \
    --exact-write-errors 0

# 3. Cross-root build in slot-b (safe_dep hits=1, manifest_dep misses=1)
run_leg "cross_root" "$SLOT_B" "$SLOT_B/project/target" \
    --min-compile-requests 3 \
    --exact-rust-hits 1 \
    --exact-rust-misses 1 \
    --exact-read-errors 0 \
    --exact-write-errors 0

# Verify runtime output & dep-info integrity in slot-b
OUT_B="$(
    cd "$SLOT_B/project"
    RUSTC_WRAPPER="$SCCACHE_BIN" CARGO_TARGET_DIR="$SLOT_B/project/target" \
        SCCACHE_BASEDIRS="$SLOT_B" RUSTFLAGS="--remap-path-prefix=$SLOT_B=/topsrc" \
        cargo run --quiet --color=never
)"
EXPECTED_MANIFEST="$(cd "$SLOT_B/project/manifest_dep" && pwd -P)"
ACTUAL_VAL="${OUT_B%%|*}"
ACTUAL_MANIFEST="${OUT_B#*|}"
[ "$ACTUAL_VAL" = "32" ] || { echo "unexpected runtime value: $OUT_B"; exit 1; }
[ "$ACTUAL_MANIFEST" = "$EXPECTED_MANIFEST" ] || {
    echo "FALSE HIT DETECTED: expected manifest $EXPECTED_MANIFEST, got $ACTUAL_MANIFEST"
    exit 1
}

python3 - "$SLOT_A" "$SLOT_B" "$SLOT_B/project/target/debug" <<'PY'
import pathlib, sys
slot_a, slot_b, debug_dir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
d_files = sorted(debug_dir.rglob("safe_dep*.d"))
assert d_files, f"no safe_dep .d files in {debug_dir}"
for p in d_files:
    raw = p.read_bytes()
    assert b"\x01" not in raw and b"\x02" not in raw, f"raw marker left in {p}"
    txt = raw.decode("utf-8")
    assert slot_a not in txt, f"foreign root {slot_a} leaked in {p}:\n{txt}"
    assert slot_b in txt, f"expected root {slot_b} missing in {p}:\n{txt}"
print(f"DEPINFO_CHECK_OK files={len(d_files)}")
PY

# 4. Input modification in slot-b must miss safe_dep + manifest_dep
cat > "$SLOT_B/project/safe_dep/src/lib.rs" <<'RS'
pub fn compute(n: u64) -> u64 {
    n * 7 + 12
}
RS
run_leg "input_change" "$SLOT_B" "$SLOT_B/project/target" \
    --min-compile-requests 3 \
    --exact-rust-hits 0 \
    --exact-rust-misses 2 \
    --exact-read-errors 0 \
    --exact-write-errors 0

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
SCCACHE_VER="$("$SCCACHE_BIN" --version)"
RUSTC_VER="$(rustc --version)"
CARGO_VER="$(cargo --version)"

python3 "$VERIFY_PY" report \
    --title "sccache Disk Regression" \
    --commit-sha "$COMMIT_SHA" \
    --sccache-version "$SCCACHE_VER" \
    --rustc-version "$RUSTC_VER" \
    --cargo-version "$CARGO_VER" \
    --backend "disk" \
    --fixture "safe_dep+manifest_dep+app" \
    --leg-files \
        "$REPORT_DIR/leg_cold.json" \
        "$REPORT_DIR/leg_l0_warm.json" \
        "$REPORT_DIR/leg_cross_root.json" \
        "$REPORT_DIR/leg_input_change.json" \
    --report-json "$REPORT_DIR/disk-regression-report.json" \
    ${GITHUB_STEP_SUMMARY:+--summary-md "$GITHUB_STEP_SUMMARY"}
